require 'busted.runner'()

-- Tests for init() function

describe("init() function", function()
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
            warn = function(...) end,
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
        settings = {}
        _G.LocalSend_user_stopped = nil

        _G.G_reader_settings = {
            readSetting = function(self, key) return settings[key] end,
            saveSetting = function(self, key, value) settings[key] = value end,
            isTrue = function(self, key) return settings[key] == true end,
            nilOrTrue = function(self, key) return settings[key] ~= false end,
            flipNilOrTrue = function(self, key) settings[key] = not self:nilOrTrue(key) end,
            flipNilOrFalse = function(self, key) settings[key] = not self:isTrue(key) end,
        }

        package.loaded["util"] = {
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

    describe("settings loading", function()
        it("should load port from settings", function()
            settings["LocalSend_port"] = "12345"

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.equal("12345", instance.port)
        end)

        it("should use default port 53317 when not set", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.equal("53317", instance.port)
        end)

        it("should use default port for invalid port", function()
            settings["LocalSend_port"] = "99999" -- Invalid

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.equal("53317", instance.port)
        end)

        it("should load save_dir from settings", function()
            settings["LocalSend_save_dir"] = "/custom/path"

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.equal("/custom/path", instance.save_dir)
        end)

        it("should use default save_dir when not set", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.equal("/mnt/us/documents", instance.save_dir)
        end)

        it("should load device_name from settings", function()
            settings["LocalSend_device_name"] = "My Device"

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.equal("My Device", instance.device_name)
        end)

        it("should default to empty device_name", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.equal("", instance.device_name)
        end)

        it("should load pin from settings", function()
            settings["LocalSend_pin"] = "1234"

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.equal("1234", instance.pin)
        end)

        it("should default to empty pin", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.equal("", instance.pin)
        end)

        it("should load use_https from settings (default true)", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_true(instance.use_https)
        end)

        it("should load use_https=false when explicitly disabled", function()
            settings["LocalSend_use_https"] = false

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_false(instance.use_https)
        end)

        it("should load autostart from settings", function()
            settings["LocalSend_autostart"] = true

            LocalSend = require("main")
            -- Don't create instance yet - need to mock start
            local start_called = false
            LocalSend.start = function() start_called = true end

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_true(instance.autostart)
        end)

        it("should load accept_ext from settings", function()
            settings["LocalSend_accept_ext"] = "epub,pdf"

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.equal("epub,pdf", instance.accept_ext)
        end)

        it("should load use_webrtc from settings (default false)", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_false(instance.use_webrtc)
        end)

        it("should load ext_dirs from settings", function()
            settings["LocalSend_ext_dirs"] = { epub = "/books", pdf = "/docs" }

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.same({ epub = "/books", pdf = "/docs" }, instance.ext_dirs)
        end)

        it("should default ext_dirs to empty table", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.same({}, instance.ext_dirs)
        end)

        it("should load routing_accept_all from settings", function()
            settings["LocalSend_routing_accept_all"] = true

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_true(instance.routing_accept_all)
        end)

        it("should load routing_enabled from settings", function()
            settings["LocalSend_routing_enabled"] = true

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_true(instance.routing_enabled)
        end)
    end)

    describe("last_transfer_count initialization", function()
        it("should initialize last_transfer_count to 0", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.equal(0, instance.last_transfer_count)
        end)
    end)

    describe("menu registration", function()
        it("should register to main menu", function()
            LocalSend = require("main")

            local menu_registered = false
            local mock_menu = {
                registerToMainMenu = function() menu_registered = true end
            }

            local instance = LocalSend:new{
                ui = { menu = mock_menu }
            }

            assert.is_true(menu_registered)
        end)
    end)

    describe("dispatcher registration", function()
        it("should call onDispatcherRegisterActions", function()
            LocalSend = require("main")

            local dispatcher_called = false
            LocalSend.onDispatcherRegisterActions = function()
                dispatcher_called = true
            end

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_true(dispatcher_called)
        end)
    end)

    describe("autostart logic", function()
        it("should call start() when autostart enabled and not user_stopped", function()
            settings["LocalSend_autostart"] = true
            _G.LocalSend_user_stopped = nil

            LocalSend = require("main")

            local start_called = false
            LocalSend.start = function() start_called = true end

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_true(start_called)
        end)

        it("should NOT call start() when autostart disabled", function()
            settings["LocalSend_autostart"] = false

            LocalSend = require("main")

            local start_called = false
            LocalSend.start = function() start_called = true end

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_false(start_called)
        end)

        it("should NOT call start() when user_stopped flag is set", function()
            settings["LocalSend_autostart"] = true
            _G.LocalSend_user_stopped = true

            LocalSend = require("main")

            local start_called = false
            LocalSend.start = function() start_called = true end

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_false(start_called)
        end)
    end)
end)
