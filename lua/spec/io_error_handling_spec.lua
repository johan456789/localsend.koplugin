require 'busted.runner'()
local helper = require("spec.test_helper")

-- Tests for io.open() and os.execute() failure handling

describe("I/O Error Handling", function()
    local LocalSend
    local path_exists_map

    setup(function()
        helper.setup_complete()
    end)

    before_each(function()
        helper.before_each()
        path_exists_map = {}
        _G._test_readFromFile_returns_nil = nil
        _G._test_readFromFile_content = nil

        -- Override pathExists to use test map
        package.loaded["util"].pathExists = function(path)
            if path == "/tmp/koreader/plugins/localsend.koplugin" then return true end
            if path == "/tmp/koreader/plugins/localsend.koplugin/localsend" then return true end
            if path_exists_map[path] ~= nil then return path_exists_map[path] end
            return false
        end

        -- Override readFromFile for test control
        package.loaded["util"].readFromFile = function(path)
            if path:match("pid$") and _G._test_readFromFile_returns_nil then
                return nil
            end
            return _G._test_readFromFile_content
        end
    end)

    describe("io.open() failure handling", function()
        describe("isRunning", function()
            it("returns false when PID file exists but cannot be read", function()
                path_exists_map["/tmp/localsend_koreader.pid"] = true
                _G._test_readFromFile_returns_nil = true

                local instance = helper.create_instance()
                local result = instance:isRunning()

                assert.is_false(result, "Should return false when PID file cannot be read")
            end)
        end)

        describe("getTransferLog", function()
            it("returns empty table when log file exists but cannot be opened", function()
                path_exists_map["/tmp/localsend_transfers.log"] = true

                local original_io_open = io.open
                _G.io.open = function(path, mode)
                    if path:match("transfers%.log$") then return nil end
                    return original_io_open(path, mode)
                end

                local instance = helper.create_instance()
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
                    if path:match("transfers%.log$") then return nil end
                    return original_io_open(path, mode)
                end

                local instance = helper.create_instance()
                local count = instance:getTransferCount()

                assert.equal(0, count, "Should return 0 when log unreadable")

                _G.io.open = original_io_open
            end)
        end)

        describe("exportExtRouting", function()
            it("returns nil when config file cannot be opened for writing", function()
                local original_io_open = io.open
                _G.io.open = function(path, mode)
                    if path:match("ext_routing%.json$") then return nil end
                    return original_io_open(path, mode)
                end

                local instance = helper.create_instance()
                instance.routing_enabled = true
                instance.ext_dirs = { epub = "/books" }

                local path = instance:exportExtRouting()

                assert.is_nil(path, "Should return nil when config file cannot be opened")

                _G.io.open = original_io_open
            end)
        end)
    end)

    describe("JSON encode failure handling", function()
        describe("exportExtRouting", function()
            it("returns nil when json.encode throws", function()
                local mock_file = { write = function() end, close = function() end }

                local original_io_open = io.open
                _G.io.open = function(path, mode)
                    if path:match("ext_routing%.json$") then return mock_file end
                    return original_io_open(path, mode)
                end

                package.loaded["json"] = {
                    encode = function(t) error("encode failed") end,
                    decode = function(s) return {} end,
                }

                package.loaded["main"] = nil
                local instance = helper.create_instance()
                instance.routing_enabled = true
                instance.ext_dirs = { epub = "/books" }

                local path = instance:exportExtRouting()

                assert.is_nil(path, "Should return nil when json.encode fails")

                _G.io.open = original_io_open
            end)
        end)
    end)
end)
