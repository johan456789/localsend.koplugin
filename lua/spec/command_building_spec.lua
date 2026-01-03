require 'busted.runner'()

-- Tests for command building and effective extension calculation
-- This tests the logic that determines what extensions are accepted

describe("Command Building Logic", function()
    local LocalSend
    local settings

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
        package.loaded["util"] = {
            args = function(t)
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

        settings = {}
        _G.G_reader_settings = {
            readSetting = function(self, key) return settings[key] end,
            saveSetting = function(self, key, value) settings[key] = value end,
            isTrue = function(self, key) return settings[key] == true end,
            nilOrTrue = function(self, key) return settings[key] ~= false end,
            flipNilOrTrue = function(self, key) settings[key] = not self:nilOrTrue(key) end,
            flipNilOrFalse = function(self, key) settings[key] = not self:isTrue(key) end,
            _reset = function()
                for k in pairs(settings) do settings[k] = nil end
            end,
        }

        _G.dofile = function(path)
            if path:match("_meta%.lua$") then
                return { version = "v1.1.1" }
            end
        end
    end)

    before_each(function()
        G_reader_settings._reset()
        package.loaded["main"] = nil
    end)

    -- Helper to get effective_accept_ext using same logic as start()
    local function getEffectiveAcceptExt(instance)
        local effective_accept_ext = instance.accept_ext
        if instance.routing_enabled and next(instance.ext_dirs) then
            if not instance.routing_accept_all then
                local exts = {}
                for ext, _ in pairs(instance.ext_dirs) do
                    table.insert(exts, ext)
                end
                table.sort(exts) -- For deterministic testing
                effective_accept_ext = table.concat(exts, ",")
            else
                effective_accept_ext = ""
            end
        end
        return effective_accept_ext
    end

    describe("effective extension calculation", function()
        it("uses accept_ext when routing is disabled", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance.routing_enabled = false
            instance.accept_ext = "epub,pdf"
            instance.ext_dirs = { mobi = "/books" }

            local result = getEffectiveAcceptExt(instance)
            assert.equal("epub,pdf", result)
        end)

        it("uses routed extensions when routing enabled and accept_all is false", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance.routing_enabled = true
            instance.routing_accept_all = false
            instance.accept_ext = "txt" -- Should be ignored
            instance.ext_dirs = { epub = "/books", pdf = "/docs" }

            local result = getEffectiveAcceptExt(instance)
            -- Should contain both extensions (sorted for determinism)
            assert.equal("epub,pdf", result)
        end)

        it("accepts all when routing enabled and accept_all is true", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance.routing_enabled = true
            instance.routing_accept_all = true
            instance.accept_ext = "txt"
            instance.ext_dirs = { epub = "/books" }

            local result = getEffectiveAcceptExt(instance)
            assert.equal("", result) -- Empty means accept all
        end)

        it("uses accept_ext when routing enabled but no routes defined", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance.routing_enabled = true
            instance.accept_ext = "epub,pdf"
            instance.ext_dirs = {}

            local result = getEffectiveAcceptExt(instance)
            assert.equal("epub,pdf", result)
        end)
    end)

    describe("settings persistence", function()
        it("loads settings from G_reader_settings on init", function()
            settings["LocalSend_port"] = "12345"
            settings["LocalSend_save_dir"] = "/custom/path"
            settings["LocalSend_device_name"] = "My Device"
            settings["LocalSend_pin"] = "1234"
            settings["LocalSend_accept_ext"] = "epub,pdf"
            settings["LocalSend_use_https"] = false
            settings["LocalSend_autostart"] = true

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.equal("12345", instance.port)
            assert.equal("/custom/path", instance.save_dir)
            assert.equal("My Device", instance.device_name)
            assert.equal("1234", instance.pin)
            assert.equal("epub,pdf", instance.accept_ext)
            assert.is_false(instance.use_https)
            assert.is_true(instance.autostart)
        end)

        it("uses defaults when settings are nil", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.equal("53317", instance.port)
            assert.equal("/mnt/us/documents", instance.save_dir)
            assert.equal("", instance.device_name)
            assert.equal("", instance.pin)
            assert.equal("", instance.accept_ext)
            assert.is_true(instance.use_https) -- Default is true (nilOrTrue)
            assert.is_false(instance.autostart)
        end)

        it("rejects invalid port and uses default", function()
            settings["LocalSend_port"] = "invalid"

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.equal("53317", instance.port)
        end)

        it("rejects out of range port and uses default", function()
            settings["LocalSend_port"] = "99999"

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.equal("53317", instance.port)
        end)
    end)

    describe("HTTPS and WebRTC flags", function()
        it("use_https defaults to true", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_true(instance.use_https)
        end)

        it("use_webrtc defaults to false", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_false(instance.use_webrtc)
        end)

        it("respects explicit false for use_https", function()
            settings["LocalSend_use_https"] = false

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_false(instance.use_https)
        end)

        it("respects explicit true for use_webrtc", function()
            settings["LocalSend_use_webrtc"] = true

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_true(instance.use_webrtc)
        end)
    end)
end)
