require 'busted.runner'()

-- Tests for restart() and rotateCertificates() functions

describe("Server Restart and Certificate Functions", function()
    local LocalSend
    local settings
    local notifications_shown
    local os_execute_calls

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
        package.loaded["gettext"] = setmetatable({}, {
            __call = function(_, s) return s end,
        })
        package.loaded["json"] = {
            encode = function(t) return "{}" end,
            decode = function(s) return {} end,
        }
        package.loaded["localsend_utils"] = require("localsend_utils")

        _G.dofile = function(path)
            if path:match("_meta%.lua$") then
                return { version = "v1.1.1" }
            end
        end
    end)

    before_each(function()
        settings = {}
        notifications_shown = {}
        os_execute_calls = {}

        _G.G_reader_settings = {
            readSetting = function(self, key) return settings[key] end,
            saveSetting = function(self, key, value) settings[key] = value end,
            isTrue = function(self, key) return settings[key] == true end,
            nilOrTrue = function(self, key) return settings[key] ~= false end,
            flipNilOrTrue = function(self, key) settings[key] = not self:nilOrTrue(key) end,
            flipNilOrFalse = function(self, key) settings[key] = not self:isTrue(key) end,
        }

        package.loaded["ui/widget/infomessage"] = {
            new = function(self, o)
                table.insert(notifications_shown, o)
                return o
            end,
        }

        package.loaded["ui/network/manager"] = {
            isOnline = function() return true end,
            runWhenOnline = function(self, callback) callback() end,
            runWhenConnected = function(self, callback) callback() end,
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

        _G.os.execute = function(cmd)
            table.insert(os_execute_calls, cmd)
            return 0
        end

        _G.os.remove = function() return true end

        package.loaded["main"] = nil
    end)

    describe("restart", function()
        it("stops server then starts when running", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local stop_called = false
            local start_called = false
            local stop_called_first = false

            instance.isRunning = function() return true end
            instance.stopServer = function(self, silent)
                stop_called = true
                if not start_called then
                    stop_called_first = true
                end
            end
            instance.start = function()
                start_called = true
            end

            instance:restart()

            assert.is_true(stop_called, "Should call stopServer")
            assert.is_true(start_called, "Should call start")
            assert.is_true(stop_called_first, "Should stop before starting")
        end)

        it("only starts when not running", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local stop_called = false
            local start_called = false

            instance.isRunning = function() return false end
            instance.stopServer = function(self, silent)
                stop_called = true
            end
            instance.start = function()
                start_called = true
            end

            instance:restart()

            assert.is_false(stop_called, "Should not call stopServer when not running")
            assert.is_true(start_called, "Should call start")
        end)

        it("calls stopServer when running", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local stop_called = false

            instance.isRunning = function() return true end
            instance.stopServer = function(self)
                stop_called = true
            end
            instance.start = function() end

            instance:restart()

            assert.is_true(stop_called, "Should call stopServer when running")
        end)
    end)

    describe("rotateCertificates", function()
        it("removes certificate files from certs folder", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            os_execute_calls = {}
            instance:rotateCertificates()

            -- Should have 2 rm commands for key and cert in certs folder
            local rm_count = 0
            for _, cmd in ipairs(os_execute_calls) do
                if cmd:match("^'rm' '%-f'") then
                    rm_count = rm_count + 1
                end
            end
            assert.equal(2, rm_count, "Should remove 2 certificate files")
        end)

        it("removes server.key.pem from certs folder", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            os_execute_calls = {}
            instance:rotateCertificates()

            local found = false
            for _, cmd in ipairs(os_execute_calls) do
                if cmd:match("certs/server%.key%.pem") then
                    found = true
                    break
                end
            end
            assert.is_true(found, "Should remove server.key.pem from certs folder")
        end)

        it("removes server.crt from certs folder", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            os_execute_calls = {}
            instance:rotateCertificates()

            local found = false
            for _, cmd in ipairs(os_execute_calls) do
                if cmd:match("certs/server%.crt") then
                    found = true
                    break
                end
            end
            assert.is_true(found, "Should remove server.crt from certs folder")
        end)

        it("shows success notification", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            notifications_shown = {}
            instance:rotateCertificates()

            local found = false
            for _, n in ipairs(notifications_shown) do
                if n.text and (n.text:match("Certificates cleared") or n.text:match("generated")) then
                    found = true
                    break
                end
            end
            assert.is_true(found, "Should show success notification")
        end)

        it("notification has timeout", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            notifications_shown = {}
            instance:rotateCertificates()

            assert.equal(3, notifications_shown[1].timeout)
        end)
    end)

    describe("onExit lifecycle", function()
        it("stops server on exit when running", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local stop_called = false
            instance.isRunning = function() return true end
            instance.stopServer = function(self, silent)
                stop_called = true
            end

            instance:onExit()

            assert.is_true(stop_called, "Should stop server on exit")
        end)

        it("does not stop server on exit when not running", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local stop_called = false
            instance.isRunning = function() return false end
            instance.stopServer = function(self, silent)
                stop_called = true
            end

            instance:onExit()

            assert.is_false(stop_called, "Should not call stopServer when not running")
        end)

        it("calls stopServer on exit", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local stop_called = false
            instance.isRunning = function() return true end
            instance.stopServer = function(self)
                stop_called = true
            end

            instance:onExit()

            assert.is_true(stop_called, "Should call stopServer on exit")
        end)
    end)
end)
