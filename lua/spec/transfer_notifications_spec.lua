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

        package.loaded["ui/network/manager"] = {
            isOnline = function() return true end,
            runWhenOnline = function(self, callback) callback() end,
            runWhenConnected = function(self, callback) callback() end,
        }
        package.loaded["ui/uimanager"] = {
            show = function() end,
            close = function() end,
            scheduleIn = function(self, delay, callback)
                table.insert(scheduled_callbacks, { delay = delay, callback = callback })
            end,
            unschedule = function() end,
            preventStandby = function() end,
            allowStandby = function() end,
            getElapsedTimeSinceBoot = function() return { sec = 0, usec = 0 } end,
        }
        package.loaded["pluginshare"] = {}

        -- Mock io.open for transfer log
        local original_io_open = io.open
        _G.io.open = function(path, mode)
            if path == "/tmp/localsend_transfers.log" and mode == "r" then
                if not transfer_log_exists then return nil end
                local pos = 1
                local byte_pos = 0
                -- Calculate total byte length
                local total_bytes = 0
                for _, line in ipairs(transfer_log_content) do
                    total_bytes = total_bytes + #line + 1  -- +1 for newline
                end

                return {
                    lines = function(self)
                        return function()
                            if pos > #transfer_log_content then return nil end
                            local line = transfer_log_content[pos]
                            byte_pos = byte_pos + #line + 1
                            pos = pos + 1
                            return line
                        end
                    end,
                    seek = function(self, whence, offset)
                        offset = offset or 0
                        if whence == "end" then
                            byte_pos = total_bytes
                            return total_bytes
                        elseif whence == "set" then
                            byte_pos = offset
                            -- Find which line we're at
                            local current_bytes = 0
                            pos = 1
                            for i, line in ipairs(transfer_log_content) do
                                local line_end = current_bytes + #line + 1
                                if offset < line_end then
                                    pos = i
                                    break
                                end
                                current_bytes = line_end
                                pos = i + 1
                            end
                            return byte_pos
                        else
                            return byte_pos
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

            -- Pass current generation
            local gen = LocalSend._ServerState.polling_generation
            instance:checkForNewTransfers(gen)

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
            -- Reset ServerState for test
            LocalSend._ServerState.last_log_position = 0
            LocalSend._ServerState.polling_generation = 0

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.isRunning = function() return true end

            -- Pass current generation
            local gen = LocalSend._ServerState.polling_generation
            instance:checkForNewTransfers(gen)

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
            -- Reset ServerState for test
            LocalSend._ServerState.last_log_position = 0
            LocalSend._ServerState.polling_generation = 0

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.isRunning = function() return true end

            -- Pass current generation
            local gen = LocalSend._ServerState.polling_generation
            instance:checkForNewTransfers(gen)

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
            -- Set position to end of file (already read)
            LocalSend._ServerState.last_log_position = #transfer_log_content[1] + 1
            LocalSend._ServerState.polling_generation = 0

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.isRunning = function() return true end

            -- Pass current generation
            local gen = LocalSend._ServerState.polling_generation
            instance:checkForNewTransfers(gen)

            assert.equal(0, #notifications_shown)
        end)

        it("updates last_log_position after checking (optimized log reading)", function()
            is_running = true
            transfer_log_exists = true
            transfer_log_content = {
                '{"filename":"book.epub","size":1024}',
            }

            LocalSend = require("main")
            -- Reset ServerState for test
            LocalSend._ServerState.last_log_position = 0
            LocalSend._ServerState.polling_generation = 0

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.isRunning = function() return true end

            -- Pass current generation
            local gen = LocalSend._ServerState.polling_generation
            instance:checkForNewTransfers(gen)

            -- Position should be updated to track where we left off
            assert.is_true(LocalSend._ServerState.last_log_position > 0)
        end)

        it("schedules next check in 15 seconds (POLLING_INTERVAL_IDLE)", function()
            is_running = true
            transfer_log_exists = false

            LocalSend = require("main")
            -- Reset ServerState for test
            LocalSend._ServerState.last_log_position = 0
            LocalSend._ServerState.polling_generation = 0

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.isRunning = function() return true end

            -- Pass current generation
            local gen = LocalSend._ServerState.polling_generation
            instance:checkForNewTransfers(gen)

            assert.equal(1, #scheduled_callbacks)
            assert.equal(15, scheduled_callbacks[1].delay)
        end)

        it("does not schedule next check when server stopped during check", function()
            is_running = true
            transfer_log_exists = false

            LocalSend = require("main")
            -- Reset ServerState for test
            LocalSend._ServerState.last_log_position = 0
            LocalSend._ServerState.polling_generation = 0

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            -- Server is running at start but stopped by end
            local check_count = 0
            instance.isRunning = function()
                check_count = check_count + 1
                return check_count <= 1 -- Running first time, stopped second time
            end

            -- Pass current generation
            local gen = LocalSend._ServerState.polling_generation
            instance:checkForNewTransfers(gen)

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
            -- Simulate having already read the first 2 files by setting position
            -- Each line is ~36-37 chars + newline, so position after 2 lines is ~75 bytes
            local pos_after_two = #transfer_log_content[1] + 1 + #transfer_log_content[2] + 1
            LocalSend._ServerState.last_log_position = pos_after_two
            LocalSend._ServerState.polling_generation = 0

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.isRunning = function() return true end

            -- Add a new file
            table.insert(transfer_log_content, '{"filename":"new.pdf","size":3072}')

            -- Pass current generation
            local gen = LocalSend._ServerState.polling_generation
            instance:checkForNewTransfers(gen)

            assert.equal(1, #notifications_shown)
            -- Template function uses %1 placeholder
            local text = notifications_shown[1].text
            assert.truthy(text:match("File received") or text:match("received"))
        end)
    end)
end)
