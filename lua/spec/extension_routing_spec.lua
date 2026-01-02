require 'busted.runner'()

-- Tests for extension routing functionality

describe("Extension Routing", function()
    local LocalSend
    local saved_settings

    setup(function()
        -- Mock dependencies
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
            encode = function(t)
                -- Simple but functional JSON encoder
                if type(t) ~= "table" then return tostring(t) end
                local parts = {}
                for k, v in pairs(t) do
                    local val = type(v) == "string" and ('"' .. v .. '"') or tostring(v)
                    table.insert(parts, '"' .. k .. '":' .. val)
                end
                table.sort(parts) -- For deterministic output
                return "{" .. table.concat(parts, ",") .. "}"
            end,
            decode = function(s) return {} end,
        }
        package.loaded["localsend_utils"] = require("localsend_utils")

        saved_settings = {}
        _G.G_reader_settings = {
            readSetting = function(self, key) return saved_settings[key] end,
            saveSetting = function(self, key, value) saved_settings[key] = value end,
            isTrue = function(self, key) return saved_settings[key] == true end,
            nilOrTrue = function(self, key) return saved_settings[key] ~= false end,
            flipNilOrTrue = function(self, key) saved_settings[key] = not self:nilOrTrue(key) end,
            flipNilOrFalse = function(self, key) saved_settings[key] = not self:isTrue(key) end,
            _reset = function()
                for k in pairs(saved_settings) do saved_settings[k] = nil end
            end,
        }

        _G.dofile = function(path)
            if path:match("_meta%.lua$") then
                return { version = "v1.1.1" }
            end
            error("dofile not mocked for: " .. path)
        end
    end)

    before_each(function()
        G_reader_settings._reset()
        package.loaded["main"] = nil
    end)

    describe("addExtensionRoute", function()
        it("should lowercase extension", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance:addExtensionRoute("EPUB", "/books")

            assert.is_not_nil(instance.ext_dirs["epub"])
            assert.is_nil(instance.ext_dirs["EPUB"])
            assert.equal("/books", instance.ext_dirs["epub"])
        end)

        it("should auto-enable routing on first route", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_false(instance.routing_enabled)

            instance:addExtensionRoute("epub", "/books")

            assert.is_true(instance.routing_enabled)
        end)

        it("should persist routes to settings", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance:addExtensionRoute("epub", "/books")
            instance:addExtensionRoute("pdf", "/docs")

            local saved = saved_settings["LocalSend_ext_dirs"]
            assert.is_not_nil(saved)
            assert.equal("/books", saved["epub"])
            assert.equal("/docs", saved["pdf"])
        end)

        it("should overwrite existing route for same extension", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance:addExtensionRoute("epub", "/old")
            instance:addExtensionRoute("epub", "/new")

            assert.equal("/new", instance.ext_dirs["epub"])
        end)
    end)

    describe("removeExtensionRoute", function()
        it("should remove route", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance:addExtensionRoute("epub", "/books")
            instance:addExtensionRoute("pdf", "/docs")

            instance:removeExtensionRoute("epub")

            assert.is_nil(instance.ext_dirs["epub"])
            assert.equal("/docs", instance.ext_dirs["pdf"])
        end)

        it("should handle case-insensitive removal", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance:addExtensionRoute("epub", "/books")
            instance:removeExtensionRoute("EPUB")

            assert.is_nil(instance.ext_dirs["epub"])
        end)

        it("should not error when removing non-existent route", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.has_no.errors(function()
                instance:removeExtensionRoute("nonexistent")
            end)
        end)
    end)

    describe("exportExtRouting", function()
        it("should return nil when routing disabled", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance.routing_enabled = false
            instance.ext_dirs = { epub = "/books" }

            local result = instance:exportExtRouting()
            assert.is_nil(result)
        end)

        it("should return nil when no routes configured", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance.routing_enabled = true
            instance.ext_dirs = {}

            local result = instance:exportExtRouting()
            assert.is_nil(result)
        end)

        it("should not include default when routing_accept_all is false", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance.routing_enabled = true
            instance.routing_accept_all = false
            instance.ext_dirs = { epub = "/books" }
            instance.save_dir = "/default"

            -- Mock io.open to capture what's written
            local written_content = nil
            local mock_file = {
                write = function(self, content) written_content = content end,
                close = function() end,
            }
            local original_io_open = io.open
            io.open = function(path, mode)
                if mode == "w" then return mock_file end
                return original_io_open(path, mode)
            end

            instance:exportExtRouting()

            io.open = original_io_open

            assert.is_not_nil(written_content)
            assert.is_nil(written_content:match('"default"'))
        end)

        it("should include default when routing_accept_all is true", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance.routing_enabled = true
            instance.routing_accept_all = true
            instance.ext_dirs = { epub = "/books" }
            instance.save_dir = "/default"

            local written_content = nil
            local mock_file = {
                write = function(self, content) written_content = content end,
                close = function() end,
            }
            local original_io_open = io.open
            io.open = function(path, mode)
                if mode == "w" then return mock_file end
                return original_io_open(path, mode)
            end

            instance:exportExtRouting()

            io.open = original_io_open

            assert.is_not_nil(written_content)
            assert.is_not_nil(written_content:match('"default"'))
            assert.is_not_nil(written_content:match('"/default"'))
        end)
    end)
end)
