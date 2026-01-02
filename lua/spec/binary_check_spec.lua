require 'busted.runner'()

-- Tests for binary existence check behavior

describe("Binary Existence Check", function()
    setup(function()
        -- These mocks must be set before requiring main.lua
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
        package.loaded["ui/widget/infomessage"] = { new = function(self, o) return o end }
        package.loaded["ui/widget/inputdialog"] = { new = function(self, o) return o end }
        package.loaded["ui/widget/pathchooser"] = { new = function(self, o) return o end }
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
        -- Clear the cached module to reload it fresh
        package.loaded["main"] = nil
    end)

    describe("when binary is missing", function()
        it("returns disabled module", function()
            -- Mock pathExists to report binary as missing
            package.loaded["util"] = {
                pathExists = function(path)
                    if path == "/tmp/koreader/plugins/localsend.koplugin" then return true end
                    if path == "/tmp/koreader/plugins/localsend.koplugin/localsend" then return false end -- Binary missing!
                    return false
                end,
            }

            package.loaded["main"] = nil
            local result = require("main")

            assert.is_table(result)
            assert.is_true(result.disabled, "Module should be disabled when binary missing")
        end)

        it("has only disabled field when binary missing", function()
            package.loaded["util"] = {
                pathExists = function(path)
                    if path == "/tmp/koreader/plugins/localsend.koplugin" then return true end
                    if path == "/tmp/koreader/plugins/localsend.koplugin/localsend" then return false end
                    return false
                end,
            }

            package.loaded["main"] = nil
            local result = require("main")

            -- Should only have the disabled field
            local count = 0
            for _ in pairs(result) do
                count = count + 1
            end
            assert.equal(1, count, "Should have exactly 1 field (disabled)")
            assert.is_true(result.disabled)
        end)
    end)

    describe("when binary exists", function()
        it("returns full module", function()
            package.loaded["util"] = {
                pathExists = function(path)
                    if path == "/tmp/koreader/plugins/localsend.koplugin" then return true end
                    if path == "/tmp/koreader/plugins/localsend.koplugin/localsend" then return true end
                    return false
                end,
            }

            package.loaded["main"] = nil
            local result = require("main")

            assert.is_nil(result.disabled, "Module should not be disabled when binary exists")
            assert.is_not_nil(result.name, "Module should have name field")
            assert.equal("LocalSend", result.name)
        end)

        it("has init method", function()
            package.loaded["util"] = {
                pathExists = function(path)
                    if path == "/tmp/koreader/plugins/localsend.koplugin" then return true end
                    if path == "/tmp/koreader/plugins/localsend.koplugin/localsend" then return true end
                    return false
                end,
            }

            package.loaded["main"] = nil
            local result = require("main")

            assert.is_function(result.init, "Module should have init method")
        end)

        it("has start method", function()
            package.loaded["util"] = {
                pathExists = function(path)
                    if path == "/tmp/koreader/plugins/localsend.koplugin" then return true end
                    if path == "/tmp/koreader/plugins/localsend.koplugin/localsend" then return true end
                    return false
                end,
            }

            package.loaded["main"] = nil
            local result = require("main")

            assert.is_function(result.start, "Module should have start method")
        end)

        it("has isRunning method", function()
            package.loaded["util"] = {
                pathExists = function(path)
                    if path == "/tmp/koreader/plugins/localsend.koplugin" then return true end
                    if path == "/tmp/koreader/plugins/localsend.koplugin/localsend" then return true end
                    return false
                end,
            }

            package.loaded["main"] = nil
            local result = require("main")

            assert.is_function(result.isRunning, "Module should have isRunning method")
        end)
    end)
end)
