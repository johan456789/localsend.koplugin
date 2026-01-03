require 'busted.runner'()

-- Tests for clearTransferLog function

describe("clearTransferLog", function()
    local LocalSend
    local removed_files

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
        removed_files = {}

        _G.G_reader_settings = {
            readSetting = function() return nil end,
            saveSetting = function() end,
            isTrue = function() return false end,
            nilOrTrue = function() return true end,
            flipNilOrTrue = function() end,
            flipNilOrFalse = function() end,
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

        _G.os.remove = function(path)
            table.insert(removed_files, path)
            return true
        end

        package.loaded["localsend_utils"] = require("localsend_utils")
        package.loaded["main"] = nil
    end)

    describe("file removal", function()
        it("should remove the transfer log file", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            removed_files = {}
            instance:clearTransferLog()

            local found_log_removal = false
            for _, path in ipairs(removed_files) do
                if path == "/tmp/localsend_transfers.log" then
                    found_log_removal = true
                    break
                end
            end
            assert.is_true(found_log_removal, "Should remove transfer log file")
        end)
    end)

    describe("counter reset", function()
        it("should reset last_transfer_count to 0", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            -- Set count to something non-zero
            instance.last_transfer_count = 10

            instance:clearTransferLog()

            assert.equal(0, instance.last_transfer_count,
                "Should reset last_transfer_count to 0")
        end)

        it("should work when count is already 0", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance.last_transfer_count = 0

            assert.has_no.errors(function()
                instance:clearTransferLog()
            end)
            assert.equal(0, instance.last_transfer_count)
        end)
    end)

    describe("edge cases", function()
        it("should not error when file doesn't exist", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            _G.os.remove = function(path)
                -- Simulate file not existing (still returns true in Lua)
                return true
            end

            assert.has_no.errors(function()
                instance:clearTransferLog()
            end)
        end)

        it("should handle os.remove returning nil", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            _G.os.remove = function(path)
                return nil, "file not found"
            end

            -- Should not error even if remove fails
            assert.has_no.errors(function()
                instance:clearTransferLog()
            end)
            -- Count should still be reset
            assert.equal(0, instance.last_transfer_count)
        end)
    end)
end)
