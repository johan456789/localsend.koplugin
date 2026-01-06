require 'busted.runner'()
local helper = require("spec.test_helper")

-- Tests for checkForNewTransfers - polling for new file notifications

describe("checkForNewTransfers", function()
    local transfer_log_content
    local transfer_log_exists

    setup(function()
        helper.setup_complete()
    end)

    before_each(function()
        helper.before_each()
        transfer_log_content = {}
        transfer_log_exists = false

        -- Override pathExists for transfer log
        local base_pathExists = package.loaded["util"].pathExists
        package.loaded["util"].pathExists = function(path)
            if path == "/tmp/localsend_transfers.log" then return transfer_log_exists end
            return base_pathExists(path)
        end

        -- Mock json.decode for transfer entries
        package.loaded["json"].decode = function(s)
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
        end

        -- Mock io.open for transfer log
        local original_io_open = io.open
        _G.io.open = function(path, mode)
            if path == "/tmp/localsend_transfers.log" and mode == "r" then
                if not transfer_log_exists then return nil end
                local pos = 1
                local byte_pos = 0
                local total_bytes = 0
                for _, line in ipairs(transfer_log_content) do
                    total_bytes = total_bytes + #line + 1
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
    end)

    describe("when server is not running", function()
        it("does nothing and does not schedule next check", function()
            local LocalSend = require("main")
            local instance = helper.create_instance()
            instance.isRunning = function() return false end

            helper.state.scheduled_tasks = {}

            instance:_checkForNewTransfers()

            assert.equal(0, #helper.state.notifications_shown, "Should not show notification")
            assert.equal(0, #helper.state.scheduled_tasks, "Should not schedule next check")
        end)
    end)

    describe("when server is running", function()
        it("shows notification for single new transfer", function()
            transfer_log_exists = true
            transfer_log_content = {
                '{"filename":"book.epub","size":1024}',
            }

            local LocalSend = require("main")
            LocalSend._ServerState.last_log_position = 0
            LocalSend._ServerState.polling_generation = 0

            local instance = helper.create_instance()
            instance.isRunning = function() return true end

            instance:_checkForNewTransfers()

            assert.equal(1, #helper.state.notifications_shown)
            local text = helper.state.notifications_shown[1].text
            assert.truthy(text:match("File received") or text:match("received"))
        end)

        it("shows notification for multiple new transfers", function()
            transfer_log_exists = true
            transfer_log_content = {
                '{"filename":"book1.epub","size":1024}',
                '{"filename":"book2.pdf","size":2048}',
                '{"filename":"book3.mobi","size":3072}',
            }

            local LocalSend = require("main")
            LocalSend._ServerState.last_log_position = 0
            LocalSend._ServerState.polling_generation = 0

            local instance = helper.create_instance()
            instance.isRunning = function() return true end

            instance:_checkForNewTransfers()

            assert.equal(1, #helper.state.notifications_shown)
            local text = helper.state.notifications_shown[1].text
            assert.truthy(text:match("files received") or text:match("received"))
        end)

        it("does not show notification when no new transfers", function()
            transfer_log_exists = true
            transfer_log_content = {
                '{"filename":"old.epub","size":1024}',
            }

            local LocalSend = require("main")
            LocalSend._ServerState.last_log_position = #transfer_log_content[1] + 1
            LocalSend._ServerState.polling_generation = 0

            local instance = helper.create_instance()
            instance.isRunning = function() return true end

            helper.state.notifications_shown = {}

            instance:_checkForNewTransfers()

            assert.equal(0, #helper.state.notifications_shown)
        end)

        it("updates last_log_position after checking", function()
            transfer_log_exists = true
            transfer_log_content = {
                '{"filename":"book.epub","size":1024}',
            }

            local LocalSend = require("main")
            LocalSend._ServerState.last_log_position = 0
            LocalSend._ServerState.polling_generation = 0

            local instance = helper.create_instance()
            instance.isRunning = function() return true end

            instance:_checkForNewTransfers()

            assert.is_true(LocalSend._ServerState.last_log_position > 0)
        end)

        it("does not self-schedule (sentinel polling handles scheduling)", function()
            transfer_log_exists = false

            local LocalSend = require("main")
            LocalSend._ServerState.last_log_position = 0

            local instance = helper.create_instance()
            instance.isRunning = function() return true end

            helper.state.scheduled_tasks = {}

            instance:_checkForNewTransfers()

            assert.equal(0, #helper.state.scheduled_tasks, "checkForNewTransfers should not self-schedule")
        end)
    end)

    describe("incremental detection", function()
        it("only notifies about new transfers, not old ones", function()
            transfer_log_exists = true
            transfer_log_content = {
                '{"filename":"old1.epub","size":1024}',
                '{"filename":"old2.epub","size":2048}',
            }

            local LocalSend = require("main")
            local pos_after_two = #transfer_log_content[1] + 1 + #transfer_log_content[2] + 1
            LocalSend._ServerState.last_log_position = pos_after_two
            LocalSend._ServerState.polling_generation = 0

            local instance = helper.create_instance()
            instance.isRunning = function() return true end

            -- Add a new file
            table.insert(transfer_log_content, '{"filename":"new.pdf","size":3072}')

            helper.state.notifications_shown = {}

            instance:_checkForNewTransfers()

            assert.equal(1, #helper.state.notifications_shown)
            local text = helper.state.notifications_shown[1].text
            assert.truthy(text:match("File received") or text:match("received"))
        end)
    end)

    describe("notification widget type", function()
        it("should use Notification (toast) instead of InfoMessage (modal)", function()
            transfer_log_exists = true
            transfer_log_content = {
                '{"filename":"book.epub","size":1024}',
            }

            local LocalSend = require("main")
            LocalSend._ServerState.last_log_position = 0
            LocalSend._ServerState.polling_generation = 0

            local instance = helper.create_instance()
            instance.isRunning = function() return true end

            helper.state.notifications_shown = {}
            helper.state.dialogs_shown = {}

            instance:_checkForNewTransfers()

            -- Should use Notification (toast) not InfoMessage
            assert.equal(1, #helper.state.notifications_shown,
                "Should use Notification (toast) for file transfer notifications")

            local text = helper.state.notifications_shown[1].text
            assert.truthy(text:match("File received") or text:match("received"),
                "Toast notification should contain filename info")
        end)

        it("should set appropriate timeout for toast notifications", function()
            transfer_log_exists = true
            transfer_log_content = {
                '{"filename":"book.epub","size":1024}',
            }

            local LocalSend = require("main")
            LocalSend._ServerState.last_log_position = 0
            LocalSend._ServerState.polling_generation = 0

            local instance = helper.create_instance()
            instance.isRunning = function() return true end

            helper.state.notifications_shown = {}

            instance:_checkForNewTransfers()

            assert.equal(1, #helper.state.notifications_shown)
            local timeout = helper.state.notifications_shown[1].timeout
            assert.is_truthy(timeout, "Toast notification should have a timeout")
            assert.is_true(timeout >= 2 and timeout <= 5,
                "Toast timeout should be between 2 and 5 seconds")
        end)
    end)
end)
