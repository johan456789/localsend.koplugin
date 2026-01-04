require 'busted.runner'()

-- Tests for the stop() wrapper function
-- Note: stopServer now uses SIGKILL and always succeeds (no graceful/force distinction)

describe("stop() wrapper function", function()
    local LocalSend
    local notifications_shown

    setup(function()
        package.loaded["ffi/util"] = {
            template = function(s, ...) return s end,
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

        _G.G_reader_settings = {
            readSetting = function() return nil end,
            saveSetting = function() end,
            isTrue = function() return false end,
            nilOrTrue = function() return true end,
            flipNilOrTrue = function() end,
            flipNilOrFalse = function() end,
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
        }

        package.loaded["ui/widget/infomessage"] = {
            new = function(self, o)
                table.insert(notifications_shown, o)
                return o
            end,
        }

        package.loaded["ui/widget/notification"] = {
            new = function(self, o)
                table.insert(notifications_shown, o)
                return o
            end,
        }
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
        }
        package.loaded["pluginshare"] = {}

        package.loaded["localsend_utils"] = require("localsend_utils")
        package.loaded["main"] = nil
    end)

    describe("user_stopped flag", function()
        it("should set user_stopped flag in ServerState", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.stopServer = function() return true end

            instance:stop()

            assert.is_true(LocalSend._ServerState.user_stopped,
                "Should set user_stopped flag")
        end)

        it("should set flag before attempting stop", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local flag_was_set = false
            instance.stopServer = function()
                flag_was_set = LocalSend._ServerState.user_stopped
                return true
            end

            instance:stop()

            assert.is_true(flag_was_set,
                "Flag should be set before stopServer is called")
        end)
    end)

    describe("simple stop behavior", function()
        it("should call stopServer once", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local stop_call_count = 0
            instance.stopServer = function(self)
                stop_call_count = stop_call_count + 1
                return true
            end

            instance:stop()

            assert.equal(1, stop_call_count, "Should call stopServer exactly once")
        end)

        it("should always show success notification", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.stopServer = function() return true end

            notifications_shown = {}
            instance:stop()

            local found_success = false
            for _, n in ipairs(notifications_shown) do
                if n.text and n.text:match("LocalSend stopped") then
                    found_success = true
                    break
                end
            end
            assert.is_true(found_success, "Should show success notification")
        end)

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
                if n.text and n.text:match("LocalSend stopped") then
                    found_notification = n
                    break
                end
            end
            assert.is_not_nil(found_notification)
            assert.equal(2, found_notification.timeout, "Success notification should have 2 second timeout")
        end)
    end)

    describe("stopServer behavior", function()
        it("should return true when no PID file exists", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            -- PID file doesn't exist (default mock behavior)
            local result = instance:stopServer()

            assert.is_true(result, "Should return true when no PID file")
        end)

        it("should remove PID file before killing process", function()
            LocalSend = require("main")

            local pid_file_removed = false
            local kill_called = false
            local removal_happened_first = false

            -- Mock pathExists to report PID file exists initially
            local pid_file_exists = true
            package.loaded["util"].pathExists = function(path)
                if path == "/tmp/koreader/plugins/localsend.koplugin" then return true end
                if path == "/tmp/koreader/plugins/localsend.koplugin/localsend" then return true end
                if path == "/tmp/localsend_koreader.pid" then return pid_file_exists end
                if path == "/proc/12345" then return true end
                return false
            end
            package.loaded["util"].readFromFile = function(path)
                if path == "/tmp/localsend_koreader.pid" then
                    return "12345"
                end
                return nil
            end

            local original_remove = os.remove
            os.remove = function(path)
                if path == "/tmp/localsend_koreader.pid" then
                    pid_file_removed = true
                    pid_file_exists = false
                    if not kill_called then
                        removal_happened_first = true
                    end
                end
                return true
            end

            local original_execute = os.execute
            os.execute = function(cmd)
                if cmd:match("kill") then
                    kill_called = true
                end
                return 0
            end

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance:stopServer()

            os.remove = original_remove
            os.execute = original_execute

            assert.is_true(pid_file_removed, "Should remove PID file")
            assert.is_true(removal_happened_first, "Should remove PID file BEFORE killing")
        end)

        it("should use SIGKILL (signal 9) for guaranteed termination", function()
            LocalSend = require("main")

            local kill_signal_used = nil

            package.loaded["util"].pathExists = function(path)
                if path == "/tmp/koreader/plugins/localsend.koplugin" then return true end
                if path == "/tmp/koreader/plugins/localsend.koplugin/localsend" then return true end
                if path == "/tmp/localsend_koreader.pid" then return true end
                if path == "/proc/12345" then return true end
                return false
            end
            package.loaded["util"].readFromFile = function(path)
                if path == "/tmp/localsend_koreader.pid" then
                    return "12345"
                end
                return nil
            end

            local original_execute = os.execute
            os.execute = function(cmd)
                if cmd:match("kill") then
                    if cmd:match("kill %-9") then
                        kill_signal_used = 9
                    end
                end
                return 0
            end

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance:stopServer()

            os.execute = original_execute

            assert.equal(9, kill_signal_used, "Should use SIGKILL (signal 9)")
        end)
    end)
end)
