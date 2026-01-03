require 'busted.runner'()

-- Tests for onToggleLocalSend function

describe("onToggleLocalSend", function()
    local LocalSend

    setup(function()
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
            retrieveNetworkInfo = function() return "WiFi" end,
        }
        package.loaded["dispatcher"] = { registerAction = function() end }
        package.loaded["ui/widget/infomessage"] = { new = function(self, o) return o end }
        package.loaded["ui/widget/inputdialog"] = { new = function(self, o) return o end }
        package.loaded["ui/widget/pathchooser"] = { new = function(self, o) return o end }
        package.loaded["ui/network/manager"] = { isOnline = function() return true end }
        package.loaded["ui/uimanager"] = {
            show = function() end,
            close = function() end,
            scheduleIn = function() end,
        }

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

        package.loaded["localsend_utils"] = require("localsend_utils")
        package.loaded["main"] = nil
    end)

    after_each(function()
        _G.LocalSend_user_stopped = nil
    end)

    describe("when server is running", function()
        it("should call stop()", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local stop_called = false
            instance.isRunning = function() return true end
            instance.stop = function() stop_called = true end

            instance:onToggleLocalSend()

            assert.is_true(stop_called, "Should call stop when running")
        end)

        it("should not call start()", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local start_called = false
            instance.isRunning = function() return true end
            instance.stop = function() end
            instance.start = function() start_called = true end

            instance:onToggleLocalSend()

            assert.is_false(start_called, "Should not call start when running")
        end)
    end)

    describe("when server is not running", function()
        it("should call start()", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local start_called = false
            instance.isRunning = function() return false end
            instance.start = function() start_called = true end

            instance:onToggleLocalSend()

            assert.is_true(start_called, "Should call start when not running")
        end)

        it("should not call stop()", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local stop_called = false
            instance.isRunning = function() return false end
            instance.stop = function() stop_called = true end
            instance.start = function() end

            instance:onToggleLocalSend()

            assert.is_false(stop_called, "Should not call stop when not running")
        end)

        it("should clear user_stopped flag", function()
            _G.LocalSend_user_stopped = true

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance.isRunning = function() return false end
            instance.start = function() end

            instance:onToggleLocalSend()

            assert.is_nil(_G.LocalSend_user_stopped,
                "Should clear user_stopped flag when starting")
        end)

        it("should clear flag before calling start()", function()
            _G.LocalSend_user_stopped = true

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local flag_during_start = nil
            instance.isRunning = function() return false end
            instance.start = function()
                flag_during_start = _G.LocalSend_user_stopped
            end

            instance:onToggleLocalSend()

            assert.is_nil(flag_during_start,
                "Flag should be cleared before start is called")
        end)
    end)

    describe("toggle behavior", function()
        it("should toggle from running to stopped", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local actions = {}
            instance.isRunning = function() return true end
            instance.stop = function() table.insert(actions, "stop") end
            instance.start = function() table.insert(actions, "start") end

            instance:onToggleLocalSend()

            assert.same({ "stop" }, actions)
        end)

        it("should toggle from stopped to running", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local actions = {}
            instance.isRunning = function() return false end
            instance.stop = function() table.insert(actions, "stop") end
            instance.start = function() table.insert(actions, "start") end

            instance:onToggleLocalSend()

            assert.same({ "start" }, actions)
        end)
    end)
end)
