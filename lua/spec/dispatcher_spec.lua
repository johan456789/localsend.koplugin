require 'busted.runner'()

-- Tests for onDispatcherRegisterActions function

describe("onDispatcherRegisterActions", function()
    local LocalSend

    -- Use a module-level table that won't be replaced
    local registered_actions = {}

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
        package.loaded["dispatcher"] = {
            registerAction = function(self, action_id, action_def)
                registered_actions[action_id] = action_def
            end,
        }
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
        -- Clear the table without replacing it
        for k in pairs(registered_actions) do
            registered_actions[k] = nil
        end

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

    describe("action registration", function()
        it("should register toggle_localsend_server action", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_not_nil(registered_actions["toggle_localsend_server"])
        end)

        it("should set category to 'none'", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.equal("none", registered_actions["toggle_localsend_server"].category)
        end)

        it("should set event to 'ToggleLocalSend'", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.equal("ToggleLocalSend", registered_actions["toggle_localsend_server"].event)
        end)

        it("should have a title", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_not_nil(registered_actions["toggle_localsend_server"].title)
            assert.truthy(registered_actions["toggle_localsend_server"].title:match("LocalSend") or
                         registered_actions["toggle_localsend_server"].title:match("Toggle"))
        end)

        it("should set general to true", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_true(registered_actions["toggle_localsend_server"].general)
        end)
    end)

    describe("dispatcher integration", function()
        it("should be called during init", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            -- Should have been called during init
            assert.is_not_nil(registered_actions["toggle_localsend_server"])
        end)
    end)
end)
