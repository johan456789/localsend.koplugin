require 'busted.runner'()

-- Tests for path picker workaround with home folder lock

describe("Path Picker", function()
    local LocalSend
    local settings
    local path_exists_map

    setup(function()
        -- Mock dependencies
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

        -- util.pathExists will check our map
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
                if path_exists_map and path_exists_map[path] ~= nil then
                    return path_exists_map[path]
                end
                return true -- Default to exists for parent dir checks
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
            error("dofile not mocked for: " .. path)
        end
    end)

    before_each(function()
        G_reader_settings._reset()
        path_exists_map = {}
        package.loaded["main"] = nil
    end)

    describe("getPickerStartPath", function()
        it("should return path unchanged when lock_home_folder is false", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            settings["lock_home_folder"] = false
            settings["home_dir"] = "/mnt/us/documents"

            local result = instance:getPickerStartPath("/mnt/us/documents/books")
            assert.equal("/mnt/us/documents/books", result)
        end)

        it("should return parent when lock_home_folder is true and path is inside home", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            settings["lock_home_folder"] = true
            settings["home_dir"] = "/mnt/us/documents"
            path_exists_map["/mnt/us/documents"] = true

            local result = instance:getPickerStartPath("/mnt/us/documents/books")
            assert.equal("/mnt/us/documents", result)
        end)

        it("should return path unchanged when outside home_dir", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            settings["lock_home_folder"] = true
            settings["home_dir"] = "/mnt/us/documents"

            local result = instance:getPickerStartPath("/mnt/us/other/folder")
            assert.equal("/mnt/us/other/folder", result)
        end)

        it("should handle root path", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            settings["lock_home_folder"] = true
            settings["home_dir"] = "/"

            local result = instance:getPickerStartPath("/")
            assert.equal("/", result)
        end)

        it("should handle trailing slashes", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            settings["lock_home_folder"] = true
            settings["home_dir"] = "/mnt/us/documents/"
            path_exists_map["/mnt/us/documents"] = true

            local result = instance:getPickerStartPath("/mnt/us/documents/books/")
            assert.equal("/mnt/us/documents", result)
        end)

        it("should handle paths with special regex characters in home_dir", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            settings["lock_home_folder"] = true
            settings["home_dir"] = "/mnt/us/my.documents"
            path_exists_map["/mnt/us/my.documents"] = true

            -- Should match exactly, not treat . as regex wildcard
            local result = instance:getPickerStartPath("/mnt/us/my.documents/books")
            assert.equal("/mnt/us/my.documents", result)
        end)

        it("should not match partial directory names", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            settings["lock_home_folder"] = true
            settings["home_dir"] = "/mnt/us/doc"

            -- /mnt/us/documents should NOT be considered inside /mnt/us/doc
            local result = instance:getPickerStartPath("/mnt/us/documents/books")
            assert.equal("/mnt/us/documents/books", result)
        end)

        it("should return original path when parent doesn't exist", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            settings["lock_home_folder"] = true
            settings["home_dir"] = "/mnt/us/documents"
            path_exists_map["/mnt/us/documents"] = false

            local result = instance:getPickerStartPath("/mnt/us/documents/books")
            assert.equal("/mnt/us/documents/books", result)
        end)

        it("should handle deeply nested paths", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            settings["lock_home_folder"] = true
            settings["home_dir"] = "/mnt/us/documents"
            path_exists_map["/mnt/us/documents/a/b"] = true

            local result = instance:getPickerStartPath("/mnt/us/documents/a/b/c")
            assert.equal("/mnt/us/documents/a/b", result)
        end)

        it("should handle single-level path", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            settings["lock_home_folder"] = true
            settings["home_dir"] = "/foo"
            path_exists_map["/"] = true

            local result = instance:getPickerStartPath("/foo")
            -- Parent of /foo is /
            assert.equal("/", result)
        end)
    end)
end)
