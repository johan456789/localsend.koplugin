require 'busted.runner'()
local helper = require("spec.test_helper")

-- Tests for transfer log parsing - handles JSON from the Go CLI

describe("Transfer Log", function()
    local LocalSend
    local mock_file_content
    local file_exists

    setup(function()
        helper.setup_complete()
    end)

    before_each(function()
        helper.before_each()
        mock_file_content = nil
        file_exists = false

        -- Override util.pathExists to include log file check
        package.loaded["util"].pathExists = function(path)
            if path == "/tmp/koreader/plugins/localsend.koplugin" then return true end
            if path == "/tmp/koreader/plugins/localsend.koplugin/localsend" then return true end
            if path == "/tmp/localsend_transfers.log" then return file_exists end
            if path:match("localsend_transfers%.log") then return file_exists end
            return false
        end

        -- Override json.decode to parse properly for tests
        package.loaded["json"] = {
            encode = function(t) return "{}" end,
            decode = function(s)
                if not s or s == "" or s == "null" then return nil end
                if not s:match('^{') then error("Invalid JSON") end
                local filename = s:match('"filename":"([^"]+)"')
                local size = s:match('"size":(%d+)')
                if filename then
                    return { filename = filename, size = tonumber(size) }
                end
                -- Empty object is valid
                if s == "{}" then return {} end
                return nil
            end,
        }

        -- Mock io.open to return our test content
        local original_io_open = io.open
        _G.io.open = function(path, mode)
            if path:match("localsend_transfers%.log") and mode == "r" then
                if not file_exists or not mock_file_content then
                    return nil
                end
                local pos = 1
                local byte_pos = 0
                -- Calculate total byte length
                local total_bytes = 0
                for _, line in ipairs(mock_file_content) do
                    total_bytes = total_bytes + #line + 1  -- +1 for newline
                end

                return {
                    lines = function(self)
                        return function()
                            if pos > #mock_file_content then return nil end
                            local line = mock_file_content[pos]
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
                            for i, line in ipairs(mock_file_content) do
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

    describe("getTransferLog", function()
        it("returns empty table when log file doesn't exist", function()
            file_exists = false
            LocalSend = require("main")
            local instance = helper.create_instance()

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
            local instance = helper.create_instance()

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
            local instance = helper.create_instance()

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
            local instance = helper.create_instance()

            local log = instance:getTransferLog()
            assert.same({}, log)
        end)

        it("handles empty JSON objects", function()
            file_exists = true
            mock_file_content = {
                '{}',
            }

            LocalSend = require("main")
            local instance = helper.create_instance()

            local log = instance:getTransferLog()
            -- Empty object is valid JSON, should be included
            assert.equal(1, #log)
        end)

        it("handles empty lines", function()
            file_exists = true
            mock_file_content = {
                '{"filename":"file1.epub","size":1024}',
                '',
                '{"filename":"file2.pdf","size":2048}',
            }

            LocalSend = require("main")
            local instance = helper.create_instance()

            local log = instance:getTransferLog()
            -- Empty line should be skipped
            assert.equal(2, #log)
        end)

        it("handles mixed valid and invalid lines", function()
            file_exists = true
            mock_file_content = {
                '{"filename":"good1.epub","size":100}',
                'bad json here',
                '',
                '{"incomplete json',
                '{"filename":"good2.pdf","size":200}',
                'null',
                '{"filename":"good3.mobi","size":300}',
            }

            LocalSend = require("main")
            local instance = helper.create_instance()

            local log = instance:getTransferLog()
            -- Only 3 valid entries
            assert.equal(3, #log)
            assert.equal("good1.epub", log[1].filename)
            assert.equal("good2.pdf", log[2].filename)
            assert.equal("good3.mobi", log[3].filename)
        end)

        it("handles corrupted file gracefully", function()
            file_exists = true
            mock_file_content = {
                'completely corrupted data!@#$%',
                '{{{{{{{{{{{{{{{',
                '"\n\n\n"',
            }

            -- Override json.decode to always error for this test
            package.loaded["json"].decode = function(s)
                error("Parse error: " .. tostring(s))
            end

            LocalSend = require("main")
            local instance = helper.create_instance()

            -- Should not error, just return empty
            local log = nil
            assert.has_no.errors(function()
                log = instance:getTransferLog()
            end)

            assert.equal(0, #log)
        end)
    end)

    describe("getTransferCount", function()
        it("returns 0 when log file doesn't exist", function()
            file_exists = false
            LocalSend = require("main")
            local instance = helper.create_instance()

            local count = instance:getTransferCount()
            assert.equal(0, count)
        end)

        it("returns cached count from ServerState (optimization)", function()
            -- getTransferCount now returns cached ServerState.transfer_count
            -- instead of reading the file (optimization for e-readers)
            LocalSend = require("main")
            LocalSend._ServerState.transfer_count = 5

            local instance = helper.create_instance()

            local count = instance:getTransferCount()
            assert.equal(5, count)
        end)
    end)

    -- Test optimized log reading with position tracking
    describe("getNewTransfers (optimized log reading)", function()
        it("returns empty table when log file doesn't exist", function()
            file_exists = false
            LocalSend = require("main")
            -- Reset ServerState for test
            LocalSend._ServerState.last_log_position = 0

            local instance = helper.create_instance()

            local transfers = instance:getNewTransfers()
            assert.same({}, transfers)
            assert.equal(0, LocalSend._ServerState.last_log_position)
        end)

        it("returns all entries on first read", function()
            file_exists = true
            mock_file_content = {
                '{"filename":"test.epub","size":1024}',
                '{"filename":"book.pdf","size":2048}',
            }

            LocalSend = require("main")
            -- Reset ServerState for test
            LocalSend._ServerState.last_log_position = 0

            local instance = helper.create_instance()

            local transfers = instance:getNewTransfers()
            assert.equal(2, #transfers)
            assert.is_true(LocalSend._ServerState.last_log_position > 0)
        end)

        it("returns only new entries on subsequent reads", function()
            file_exists = true
            mock_file_content = {
                '{"filename":"test.epub","size":1024}',
            }

            LocalSend = require("main")
            -- Reset ServerState for test
            LocalSend._ServerState.last_log_position = 0

            local instance = helper.create_instance()

            -- First read
            local transfers1 = instance:getNewTransfers()
            assert.equal(1, #transfers1)

            -- Second read (no new entries)
            local transfers2 = instance:getNewTransfers()
            assert.equal(0, #transfers2)
        end)
    end)

    -- Tests for clearTransferLog function (merged from clear_transfer_log_spec.lua)
    describe("clearTransferLog", function()
        it("should remove the transfer log file", function()
            helper.mock_os_remove()
            local instance = helper.create_instance()

            helper.state.removed_files = {}
            instance:clearTransferLog()

            local found_log_removal = false
            for _, path in ipairs(helper.state.removed_files) do
                if path == "/tmp/localsend_transfers.log" then
                    found_log_removal = true
                    break
                end
            end
            assert.is_true(found_log_removal, "Should remove transfer log file")
        end)

        it("should reset last_log_position to 0", function()
            helper.mock_os_remove()
            LocalSend = require("main")
            LocalSend._ServerState.last_log_position = 500

            local instance = helper.create_instance()
            instance:clearTransferLog()

            assert.equal(0, LocalSend._ServerState.last_log_position,
                "Should reset last_log_position to 0")
        end)

        it("should not error when file doesn't exist", function()
            local instance = helper.create_instance()

            _G.os.remove = function(path)
                return true
            end

            assert.has_no.errors(function()
                instance:clearTransferLog()
            end)
        end)
    end)

    -- Tests for showRecentTransfers (merged from recent_transfers_spec.lua)
    describe("showRecentTransfers", function()
        it("should show 'No recent transfers' message when empty", function()
            local instance = helper.create_instance()
            instance.getTransferLog = function() return {} end

            instance:showRecentTransfers()

            local notification = helper.find_notification("No recent transfers")
            assert.is_truthy(notification)
        end)

        it("should show file names from transfers", function()
            local instance = helper.create_instance()
            instance.getTransferLog = function()
                return { { filename = "test.epub", size = 1024 } }
            end

            instance:showRecentTransfers()

            local text = helper.state.notifications_shown[1].text
            assert.truthy(text:match("test%.epub"), "Should show filename")
        end)

        it("should format size in KB for medium files", function()
            local instance = helper.create_instance()
            instance.getTransferLog = function()
                return { { filename = "medium.epub", size = 51200 } }
            end

            instance:showRecentTransfers()

            local text = helper.state.notifications_shown[1].text
            assert.truthy(text:match("KB") or text:match("50"), "Should show KB size")
        end)

        it("should format size in MB for large files", function()
            local instance = helper.create_instance()
            instance.getTransferLog = function()
                return { { filename = "large.pdf", size = 5242880 } }
            end

            instance:showRecentTransfers()

            local text = helper.state.notifications_shown[1].text
            assert.truthy(text:match("MB") or text:match("5"), "Should show MB size")
        end)

        it("should handle transfers without size", function()
            local instance = helper.create_instance()
            instance.getTransferLog = function()
                return { { filename = "nosize.epub" } }
            end

            assert.has_no.errors(function()
                instance:showRecentTransfers()
            end)

            local text = helper.state.notifications_shown[1].text
            assert.truthy(text:match("nosize%.epub"), "Should show filename without size")
        end)
    end)
end)
