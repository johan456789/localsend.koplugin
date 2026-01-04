require 'busted.runner'()

-- Tests for getDeviceArch - maps uname -m output to asset architecture names

describe("getDeviceArch", function()
    local LocalSend
    local uname_output

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
        package.loaded["ui/widget/notification"] = { new = function(self, o) return o end }
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
        }
        package.loaded["pluginshare"] = {}

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

        _G.G_reader_settings = {
            readSetting = function() return nil end,
            saveSetting = function() end,
            isTrue = function() return false end,
            nilOrTrue = function() return true end,
            flipNilOrTrue = function() end,
            flipNilOrFalse = function() end,
        }

        _G.dofile = function(path)
            if path:match("_meta%.lua$") then
                return { version = "v1.1.1" }
            end
        end
    end)

    before_each(function()
        uname_output = nil
        package.loaded["main"] = nil

        -- Mock io.popen for uname -m
        local original_io_popen = io.popen
        _G.io.popen = function(cmd)
            if cmd == "uname -m" then
                return {
                    read = function(self, fmt)
                        return uname_output
                    end,
                    close = function() end,
                }
            end
            return original_io_popen(cmd)
        end
    end)

    describe("64-bit ARM detection", function()
        it("maps 'aarch64' to 'arm64'", function()
            uname_output = "aarch64"

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.equal("arm64", instance:getDeviceArch())
        end)

        it("maps 'arm64' to 'arm64'", function()
            uname_output = "arm64"

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.equal("arm64", instance:getDeviceArch())
        end)

        it("handles 'aarch64_be' (big-endian variant)", function()
            uname_output = "aarch64_be"

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.equal("arm64", instance:getDeviceArch())
        end)
    end)

    describe("32-bit ARM v7 detection", function()
        it("maps 'armv7l' to 'armv7' (common on Kindle PW+)", function()
            uname_output = "armv7l"

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.equal("armv7", instance:getDeviceArch())
        end)

        it("maps 'armv7' to 'armv7'", function()
            uname_output = "armv7"

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.equal("armv7", instance:getDeviceArch())
        end)

        it("maps 'armv7hl' to 'armv7' (hard-float variant)", function()
            uname_output = "armv7hl"

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.equal("armv7", instance:getDeviceArch())
        end)
    end)

    describe("legacy ARM detection (arm-legacy)", function()
        it("maps 'armv5' to 'arm-legacy'", function()
            uname_output = "armv5"

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.equal("arm-legacy", instance:getDeviceArch())
        end)

        it("maps 'armv5tel' to 'arm-legacy' (Kindle 3/4)", function()
            uname_output = "armv5tel"

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.equal("arm-legacy", instance:getDeviceArch())
        end)

        it("maps 'armv6l' to 'arm-legacy' (uses legacy binary)", function()
            uname_output = "armv6l"

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.equal("arm-legacy", instance:getDeviceArch())
        end)

        it("maps generic 'arm' to 'arm-legacy' (fallback)", function()
            uname_output = "arm"

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.equal("arm-legacy", instance:getDeviceArch())
        end)
    end)

    describe("unknown architecture handling", function()
        it("returns nil for 'x86_64'", function()
            uname_output = "x86_64"

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_nil(instance:getDeviceArch())
        end)

        it("returns nil for 'i686'", function()
            uname_output = "i686"

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_nil(instance:getDeviceArch())
        end)

        it("returns nil for empty output", function()
            uname_output = ""

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_nil(instance:getDeviceArch())
        end)

        it("returns nil when uname fails", function()
            uname_output = nil

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_nil(instance:getDeviceArch())
        end)
    end)

    describe("io.popen failure handling", function()
        it("returns nil when io.popen returns nil", function()
            _G.io.popen = function(cmd)
                if cmd == "uname -m" then
                    return nil
                end
            end

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_nil(instance:getDeviceArch())
        end)
    end)
end)
