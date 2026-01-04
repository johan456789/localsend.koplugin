require 'busted.runner'()

-- Tests for getTransferLog edge cases (malformed JSON, empty lines, etc.)

describe("getTransferLog edge cases", function()
    local LocalSend
    local settings
    local file_lines

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

        _G.dofile = function(path)
            if path:match("_meta%.lua$") then
                return { version = "v1.1.1" }
            end
        end
    end)

    before_each(function()
        settings = {}
        file_lines = nil

        _G.G_reader_settings = {
            readSetting = function(self, key) return settings[key] end,
            saveSetting = function(self, key, value) settings[key] = value end,
            isTrue = function(self, key) return settings[key] == true end,
            nilOrTrue = function(self, key) return settings[key] ~= false end,
            flipNilOrTrue = function(self, key) settings[key] = not self:nilOrTrue(key) end,
            flipNilOrFalse = function(self, key) settings[key] = not self:isTrue(key) end,
        }

        package.loaded["localsend_utils"] = require("localsend_utils")
        package.loaded["json"] = nil
        package.loaded["main"] = nil
    end)

    describe("malformed JSON handling", function()
        it("skips invalid JSON lines", function()
            file_lines = {
                '{"filename":"file1.epub","size":1024}',
                'not valid json at all',
                '{"filename":"file2.pdf","size":2048}',
            }

            -- Mock util.pathExists to return true for log file
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
                    if path:match("localsend_transfers%.log") then return true end
                    return false
            end,
            getFriendlySize = function(size)
                if size >= 1048576 then
                    return string.format("%.1f MB", size / 1048576)
                elseif size >= 1024 then
                    return string.format("%.1f KB", size / 1024)
                else
                    return string.format("%d B", size)
                end
                end,
            }

            -- Mock json.decode to parse properly
            package.loaded["json"] = {
                encode = function(t) return "{}" end,
                decode = function(s)
                    if s:match('^{') then
                        local filename = s:match('"filename":"([^"]+)"')
                        local size = s:match('"size":(%d+)')
                        if filename then
                            return { filename = filename, size = tonumber(size) }
                        end
                    end
                    error("Invalid JSON")
                end,
            }

            -- Mock io.open to return our test lines
            local original_io_open = io.open
            _G.io.open = function(path, mode)
                if path:match("localsend_transfers%.log") and mode == "r" then
                    local i = 0
                    return {
                        lines = function()
                            return function()
                                i = i + 1
                                return file_lines[i]
                            end
                        end,
                        close = function() end,
                    }
                end
                return original_io_open(path, mode)
            end

            package.loaded["main"] = nil
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local transfers = instance:getTransferLog()

            -- Should only have 2 valid entries
            assert.equal(2, #transfers)
            assert.equal("file1.epub", transfers[1].filename)
            assert.equal("file2.pdf", transfers[2].filename)

            _G.io.open = original_io_open
        end)

        it("handles empty lines", function()
            file_lines = {
                '{"filename":"file1.epub","size":1024}',
                '',
                '{"filename":"file2.pdf","size":2048}',
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
                    if path:match("localsend_transfers%.log") then return true end
                    return false
            end,
            getFriendlySize = function(size)
                if size >= 1048576 then
                    return string.format("%.1f MB", size / 1048576)
                elseif size >= 1024 then
                    return string.format("%.1f KB", size / 1024)
                else
                    return string.format("%d B", size)
                end
                end,
            }

            package.loaded["json"] = {
                encode = function(t) return "{}" end,
                decode = function(s)
                    if s == "" then return nil end
                    local filename = s:match('"filename":"([^"]+)"')
                    local size = s:match('"size":(%d+)')
                    if filename then
                        return { filename = filename, size = tonumber(size) }
                    end
                    return nil
                end,
            }

            local original_io_open = io.open
            _G.io.open = function(path, mode)
                if path:match("localsend_transfers%.log") and mode == "r" then
                    local i = 0
                    return {
                        lines = function()
                            return function()
                                i = i + 1
                                return file_lines[i]
                            end
                        end,
                        close = function() end,
                    }
                end
                return original_io_open(path, mode)
            end

            package.loaded["main"] = nil
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local transfers = instance:getTransferLog()

            -- Empty line should be skipped
            assert.equal(2, #transfers)

            _G.io.open = original_io_open
        end)

        it("handles json.decode returning nil", function()
            file_lines = {
                '{"filename":"file1.epub","size":1024}',
                'null',
                '{"filename":"file2.pdf","size":2048}',
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
                    if path:match("localsend_transfers%.log") then return true end
                    return false
            end,
            getFriendlySize = function(size)
                if size >= 1048576 then
                    return string.format("%.1f MB", size / 1048576)
                elseif size >= 1024 then
                    return string.format("%.1f KB", size / 1024)
                else
                    return string.format("%d B", size)
                end
                end,
            }

            package.loaded["json"] = {
                encode = function(t) return "{}" end,
                decode = function(s)
                    if s == "null" then return nil end
                    local filename = s:match('"filename":"([^"]+)"')
                    local size = s:match('"size":(%d+)')
                    if filename then
                        return { filename = filename, size = tonumber(size) }
                    end
                    return nil
                end,
            }

            local original_io_open = io.open
            _G.io.open = function(path, mode)
                if path:match("localsend_transfers%.log") and mode == "r" then
                    local i = 0
                    return {
                        lines = function()
                            return function()
                                i = i + 1
                                return file_lines[i]
                            end
                        end,
                        close = function() end,
                    }
                end
                return original_io_open(path, mode)
            end

            package.loaded["main"] = nil
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local transfers = instance:getTransferLog()

            -- Nil result should be skipped
            assert.equal(2, #transfers)

            _G.io.open = original_io_open
        end)

        it("handles mixed valid and invalid lines", function()
            file_lines = {
                '{"filename":"good1.epub","size":100}',
                'bad json here',
                '',
                '{"incomplete json',
                '{"filename":"good2.pdf","size":200}',
                'null',
                '{"filename":"good3.mobi","size":300}',
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
                    if path:match("localsend_transfers%.log") then return true end
                    return false
            end,
            getFriendlySize = function(size)
                if size >= 1048576 then
                    return string.format("%.1f MB", size / 1048576)
                elseif size >= 1024 then
                    return string.format("%.1f KB", size / 1024)
                else
                    return string.format("%d B", size)
                end
                end,
            }

            package.loaded["json"] = {
                encode = function(t) return "{}" end,
                decode = function(s)
                    if not s or s == "" or s == "null" then return nil end
                    if not s:match('^{.*}$') then error("Invalid JSON") end
                    local filename = s:match('"filename":"([^"]+)"')
                    local size = s:match('"size":(%d+)')
                    if filename then
                        return { filename = filename, size = tonumber(size) }
                    end
                    return nil
                end,
            }

            local original_io_open = io.open
            _G.io.open = function(path, mode)
                if path:match("localsend_transfers%.log") and mode == "r" then
                    local i = 0
                    return {
                        lines = function()
                            return function()
                                i = i + 1
                                return file_lines[i]
                            end
                        end,
                        close = function() end,
                    }
                end
                return original_io_open(path, mode)
            end

            package.loaded["main"] = nil
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local transfers = instance:getTransferLog()

            -- Only 3 valid entries
            assert.equal(3, #transfers)
            assert.equal("good1.epub", transfers[1].filename)
            assert.equal("good2.pdf", transfers[2].filename)
            assert.equal("good3.mobi", transfers[3].filename)

            _G.io.open = original_io_open
        end)

        it("returns empty array when file doesn't exist", function()
            package.loaded["json"] = {
                encode = function(t) return "{}" end,
                decode = function(s) return {} end,
            }

            local original_io_open = io.open
            _G.io.open = function(path, mode)
                if path:match("localsend_transfers%.log") then
                    return nil  -- File doesn't exist
                end
                return original_io_open(path, mode)
            end

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local transfers = instance:getTransferLog()

            assert.equal(0, #transfers)

            _G.io.open = original_io_open
        end)

        it("handles corrupted file gracefully", function()
            file_lines = {
                'completely corrupted data!@#$%',
                '{{{{{{{{{{{{{{{',
                '"\n\n\n"',
            }

            package.loaded["json"] = {
                encode = function(t) return "{}" end,
                decode = function(s)
                    error("Parse error: " .. s)
                end,
            }

            local original_io_open = io.open
            _G.io.open = function(path, mode)
                if path:match("localsend_transfers%.log") and mode == "r" then
                    local i = 0
                    return {
                        lines = function()
                            return function()
                                i = i + 1
                                return file_lines[i]
                            end
                        end,
                        close = function() end,
                    }
                end
                return original_io_open(path, mode)
            end

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            -- Should not error, just return empty
            local transfers = nil
            assert.has_no.errors(function()
                transfers = instance:getTransferLog()
            end)

            assert.equal(0, #transfers)

            _G.io.open = original_io_open
        end)
    end)
end)
