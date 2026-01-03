require 'busted.runner'()

-- Tests for transfer log parsing - handles JSON from the Go CLI

describe("Transfer Log", function()
    local LocalSend
    local mock_file_content
    local file_exists

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
                if path == "/tmp/localsend_transfers.log" then return file_exists end
                return false
            end,
        }
        package.loaded["gettext"] = setmetatable({}, {
            __call = function(_, s) return s end,
        })
        package.loaded["json"] = {
            encode = function(t) return "{}" end,
            decode = function(s)
                -- Simple JSON decoder for tests
                if s:match("^%s*{") then
                    local result = {}
                    for k, v in s:gmatch('"([^"]+)":"?([^",}]+)"?') do
                        if tonumber(v) then
                            result[k] = tonumber(v)
                        else
                            result[k] = v
                        end
                    end
                    return result
                end
                error("Invalid JSON")
            end,
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
        mock_file_content = nil
        file_exists = false
        package.loaded["main"] = nil

        -- Mock io.open to return our test content
        local original_io_open = io.open
        _G.io.open = function(path, mode)
            if path == "/tmp/localsend_transfers.log" and mode == "r" then
                if not file_exists or not mock_file_content then
                    return nil
                end
                local pos = 1
                return {
                    lines = function(self)
                        return function()
                            if pos > #mock_file_content then return nil end
                            local line = mock_file_content[pos]
                            pos = pos + 1
                            return line
                        end
                    end,
                    close = function() end,
                }
            end
            return original_io_open(path, mode)
        end
    end)

    describe("getTransferLog", function()
        it("returns empty table when log file doesn't exist", function()
            file_exists = false
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local log = instance:getTransferLog()
            assert.same({}, log)
        end)

        it("parses valid JSON lines", function()
            file_exists = true
            mock_file_content = {
                '{"filename":"test.epub","size":1024}',
                '{"filename":"book.pdf","size":2048}',
            }

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local log = instance:getTransferLog()
            assert.equal(2, #log)
            assert.equal("test.epub", log[1].filename)
            assert.equal(1024, log[1].size)
            assert.equal("book.pdf", log[2].filename)
        end)

        it("skips malformed JSON lines gracefully", function()
            file_exists = true
            mock_file_content = {
                '{"filename":"good.epub","size":1024}',
                'not valid json at all',
                '{"filename":"also-good.pdf","size":2048}',
            }

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local log = instance:getTransferLog()
            -- Should have 2 entries, skipping the bad one
            assert.equal(2, #log)
            assert.equal("good.epub", log[1].filename)
            assert.equal("also-good.pdf", log[2].filename)
        end)

        it("handles empty log file", function()
            file_exists = true
            mock_file_content = {}

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local log = instance:getTransferLog()
            assert.same({}, log)
        end)

        it("handles empty JSON objects", function()
            file_exists = true
            mock_file_content = {
                '{}',
            }

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local log = instance:getTransferLog()
            -- Empty object is valid JSON, should be included
            assert.equal(1, #log)
        end)
    end)

    describe("getTransferCount", function()
        it("returns 0 when log file doesn't exist", function()
            file_exists = false
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local count = instance:getTransferCount()
            assert.equal(0, count)
        end)

        it("counts all lines regardless of validity", function()
            file_exists = true
            mock_file_content = {
                '{"filename":"test.epub"}',
                'bad json',
                '{"filename":"book.pdf"}',
            }

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local count = instance:getTransferCount()
            -- Counts lines, not valid entries
            assert.equal(3, count)
        end)
    end)
end)
