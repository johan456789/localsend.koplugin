require 'busted.runner'()

-- Tests for io.open() and os.execute() failure handling

describe("I/O Error Handling", function()
    local LocalSend
    local path_exists_map
    local io_open_results
    local os_execute_results
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
        package.loaded["gettext"] = setmetatable({}, {
            __call = function(_, s) return s end,
        })
        package.loaded["localsend_utils"] = require("localsend_utils")

        _G.dofile = function(path)
            if path:match("_meta%.lua$") then
                return { version = "v1.1.1" }
            end
        end
    end)

    before_each(function()
        path_exists_map = {}
        io_open_results = {}
        os_execute_results = {}
        settings = {}

        _G.G_reader_settings = {
            readSetting = function(self, key) return settings[key] end,
            saveSetting = function(self, key, value) settings[key] = value end,
            isTrue = function(self, key) return settings[key] == true end,
            nilOrTrue = function(self, key) return settings[key] ~= false end,
            flipNilOrTrue = function() end,
            flipNilOrFalse = function() end,
        }

        -- Default path exists behavior
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
                if path_exists_map[path] ~= nil then return path_exists_map[path] end
                return false
            end,
        }

        -- Default json behavior
        package.loaded["json"] = {
            encode = function(t) return "{}" end,
            decode = function(s) return {} end,
        }

        package.loaded["main"] = nil
    end)

    describe("io.open() failure handling", function()
        describe("isRunning", function()
            it("returns false when PID file exists but cannot be opened", function()
                path_exists_map["/tmp/localsend_koreader.pid"] = true

                -- Mock io.open to return nil for PID file
                local original_io_open = io.open
                _G.io.open = function(path, mode)
                    if path:match("pid$") then
                        return nil
                    end
                    return original_io_open(path, mode)
                end

                LocalSend = require("main")
                local instance = LocalSend:new{
                    ui = { menu = { registerToMainMenu = function() end } }
                }

                local result = instance:isRunning()

                assert.is_false(result, "Should return false when PID file cannot be opened")

                _G.io.open = original_io_open
            end)
        end)

        describe("getTransferLog", function()
            it("returns empty table when log file exists but cannot be opened", function()
                path_exists_map["/tmp/localsend_transfers.log"] = true

                local original_io_open = io.open
                _G.io.open = function(path, mode)
                    if path:match("transfers%.log$") then
                        return nil
                    end
                    return original_io_open(path, mode)
                end

                LocalSend = require("main")
                local instance = LocalSend:new{
                    ui = { menu = { registerToMainMenu = function() end } }
                }

                local transfers = instance:getTransferLog()

                assert.same({}, transfers, "Should return empty table when log unreadable")

                _G.io.open = original_io_open
            end)
        end)

        describe("getTransferCount", function()
            it("returns 0 when log file exists but cannot be opened", function()
                path_exists_map["/tmp/localsend_transfers.log"] = true

                local original_io_open = io.open
                _G.io.open = function(path, mode)
                    if path:match("transfers%.log$") then
                        return nil
                    end
                    return original_io_open(path, mode)
                end

                LocalSend = require("main")
                local instance = LocalSend:new{
                    ui = { menu = { registerToMainMenu = function() end } }
                }

                local count = instance:getTransferCount()

                assert.equal(0, count, "Should return 0 when log unreadable")

                _G.io.open = original_io_open
            end)
        end)

        describe("exportExtRouting", function()
            it("returns nil when config file cannot be opened for writing", function()
                local original_io_open = io.open
                _G.io.open = function(path, mode)
                    if path:match("ext_routing%.json$") then
                        return nil
                    end
                    return original_io_open(path, mode)
                end

                LocalSend = require("main")
                local instance = LocalSend:new{
                    ui = { menu = { registerToMainMenu = function() end } }
                }
                instance.routing_enabled = true
                instance.ext_dirs = { epub = "/books" }

                local path = instance:exportExtRouting()

                assert.is_nil(path, "Should return nil when config file cannot be opened")

                _G.io.open = original_io_open
            end)
        end)
    end)

    describe("os.execute() failure handling", function()
        describe("setupCertificates", function()
            it("does not crash when mkdir fails", function()
                path_exists_map["/tmp/koreader/plugins/localsend.koplugin/certs"] = false

                _G.os.execute = function(cmd)
                    if cmd:match("mkdir") then return 1 end
                    return 0
                end

                LocalSend = require("main")
                local instance = LocalSend:new{
                    ui = { menu = { registerToMainMenu = function() end } }
                }

                -- Should not throw
                assert.has_no.errors(function()
                    instance:setupCertificates()
                end)
            end)

            it("does not crash when symlink creation fails", function()
                path_exists_map["/tmp/koreader/plugins/localsend.koplugin/certs"] = true
                path_exists_map["/tmp/koreader/plugins/localsend.koplugin/certs/server.key.pem"] = true
                path_exists_map["/tmp/koreader/plugins/localsend.koplugin/certs/server.crt"] = true

                _G.os.execute = function(cmd)
                    if cmd:match("ln %-sf") then return 1 end
                    return 0
                end

                LocalSend = require("main")
                local instance = LocalSend:new{
                    ui = { menu = { registerToMainMenu = function() end } }
                }

                -- Should not throw
                assert.has_no.errors(function()
                    instance:setupCertificates()
                end)
            end)
        end)

        describe("saveCertificates", function()
            it("does not crash when copy fails", function()
                path_exists_map["/tmp/server.key.pem"] = true
                path_exists_map["/tmp/server.crt"] = true
                path_exists_map["/tmp/koreader/plugins/localsend.koplugin/certs/server.key.pem"] = false

                _G.os.execute = function(cmd)
                    if cmd:match("cp ") then return 1 end
                    return 0
                end

                LocalSend = require("main")
                local instance = LocalSend:new{
                    ui = { menu = { registerToMainMenu = function() end } }
                }

                -- Should not throw
                assert.has_no.errors(function()
                    instance:saveCertificates()
                end)
            end)
        end)
    end)

    describe("JSON encode failure handling", function()
        describe("exportExtRouting", function()
            it("returns nil when json.encode throws", function()
                -- Create a file-like object for the mock
                local mock_file = {
                    write = function() end,
                    close = function() end,
                }

                local original_io_open = io.open
                _G.io.open = function(path, mode)
                    if path:match("ext_routing%.json$") then
                        return mock_file
                    end
                    return original_io_open(path, mode)
                end

                package.loaded["json"] = {
                    encode = function(t)
                        error("encode failed")
                    end,
                    decode = function(s) return {} end,
                }

                package.loaded["main"] = nil
                LocalSend = require("main")
                local instance = LocalSend:new{
                    ui = { menu = { registerToMainMenu = function() end } }
                }
                instance.routing_enabled = true
                instance.ext_dirs = { epub = "/books" }

                local path = instance:exportExtRouting()

                assert.is_nil(path, "Should return nil when json.encode fails")

                _G.io.open = original_io_open
            end)
        end)
    end)
end)
