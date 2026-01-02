require 'busted.runner'()

-- Tests for checkForNewTransfers - polling for new file notifications

describe("checkForNewTransfers", function()
    local LocalSend
    local transfer_log_content
    local transfer_log_exists
    local notifications_shown
    local scheduled_callbacks
    local is_running

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
        package.loaded["ui/widget/inputdialog"] = { new = function(self, o) return o end }
        package.loaded["ui/widget/pathchooser"] = { new = function(self, o) return o end }

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
        transfer_log_content = {}
        transfer_log_exists = false
        notifications_shown = {}
        scheduled_callbacks = {}
        is_running = false

        package.loaded["util"] = {
            pathExists = function(path)
                if path == "/tmp/koreader/plugins/localsend.koplugin" then return true end
                if path == "/tmp/koreader/plugins/localsend.koplugin/localsend" then return true end
                if path == "/tmp/localsend_transfers.log" then return transfer_log_exists end
                return false
            end,
        }

        package.loaded["json"] = {
            encode = function(t) return "{}" end,
            decode = function(s)
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

        package.loaded["ui/widget/infomessage"] = {
            new = function(self, o)
                table.insert(notifications_shown, o)
                return o
            end,
        }

        package.loaded["ui/uimanager"] = {
            show = function() end,
            close = function() end,
            scheduleIn = function(self, delay, callback)
                table.insert(scheduled_callbacks, { delay = delay, callback = callback })
            end,
        }

        -- Mock io.open for transfer log
        local original_io_open = io.open
        _G.io.open = function(path, mode)
            if path == "/tmp/localsend_transfers.log" and mode == "r" then
                if not transfer_log_exists then return nil end
                local pos = 1
                return {
                    lines = function(self)
                        return function()
                            if pos > #transfer_log_content then return nil end
                            local line = transfer_log_content[pos]
                            pos = pos + 1
                            return line
                        end
                    end,
                    close = function() end,
                }
            end
            return original_io_open(path, mode)
        end

        package.loaded["main"] = nil
    end)

    describe("when server is not running", function()
        it("does nothing and does not schedule next check", function()
            is_running = false

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.isRunning = function() return false end

            instance:checkForNewTransfers()

            assert.equal(0, #notifications_shown, "Should not show notification")
            assert.equal(0, #scheduled_callbacks, "Should not schedule next check")
        end)
    end)

    describe("when server is running", function()
        it("shows notification for single new transfer", function()
            is_running = true
            transfer_log_exists = true
            transfer_log_content = {
                '{"filename":"book.epub","size":1024}',
            }

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.isRunning = function() return true end
            instance.last_transfer_count = 0

            instance:checkForNewTransfers()

            assert.equal(1, #notifications_shown)
            -- Template function uses %1, %2 placeholders - check for those or actual filename
            local text = notifications_shown[1].text
            assert.truthy(text:match("File received") or text:match("received"))
        end)

        it("shows notification for multiple new transfers", function()
            is_running = true
            transfer_log_exists = true
            transfer_log_content = {
                '{"filename":"book1.epub","size":1024}',
                '{"filename":"book2.pdf","size":2048}',
                '{"filename":"book3.mobi","size":3072}',
            }

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.isRunning = function() return true end
            instance.last_transfer_count = 0

            instance:checkForNewTransfers()

            assert.equal(1, #notifications_shown)
            -- Template function uses %1, %2 placeholders
            local text = notifications_shown[1].text
            assert.truthy(text:match("files received") or text:match("received"))
        end)

        it("does not show notification when no new transfers", function()
            is_running = true
            transfer_log_exists = true
            transfer_log_content = {
                '{"filename":"old.epub","size":1024}',
            }

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.isRunning = function() return true end
            instance.last_transfer_count = 1 -- Already saw this one

            instance:checkForNewTransfers()

            assert.equal(0, #notifications_shown)
        end)

        it("updates last_transfer_count after checking", function()
            is_running = true
            transfer_log_exists = true
            transfer_log_content = {
                '{"filename":"book.epub","size":1024}',
            }

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.isRunning = function() return true end
            instance.last_transfer_count = 0

            instance:checkForNewTransfers()

            assert.equal(1, instance.last_transfer_count)
        end)

        it("schedules next check in 5 seconds", function()
            is_running = true
            transfer_log_exists = false

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.isRunning = function() return true end

            instance:checkForNewTransfers()

            assert.equal(1, #scheduled_callbacks)
            assert.equal(5, scheduled_callbacks[1].delay)
        end)

        it("does not schedule next check when server stopped during check", function()
            is_running = true
            transfer_log_exists = false

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            -- Server is running at start but stopped by end
            local check_count = 0
            instance.isRunning = function()
                check_count = check_count + 1
                return check_count <= 1 -- Running first time, stopped second time
            end

            instance:checkForNewTransfers()

            assert.equal(0, #scheduled_callbacks, "Should not schedule when server stopped")
        end)
    end)

    describe("incremental detection", function()
        it("only notifies about new transfers, not old ones", function()
            is_running = true
            transfer_log_exists = true
            transfer_log_content = {
                '{"filename":"old1.epub","size":1024}',
                '{"filename":"old2.epub","size":2048}',
            }

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.isRunning = function() return true end
            instance.last_transfer_count = 2

            -- Add a new file
            table.insert(transfer_log_content, '{"filename":"new.pdf","size":3072}')

            instance:checkForNewTransfers()

            assert.equal(1, #notifications_shown)
            -- Template function uses %1 placeholder
            local text = notifications_shown[1].text
            assert.truthy(text:match("File received") or text:match("received"))
        end)
    end)
end)
