require 'busted.runner'()
local helper = require("spec.test_helper")

-- Tests for getDeviceArch - maps uname -m output to asset architecture names

describe("getDeviceArch", function()
    local LocalSend
    local uname_output

    setup(function()
        helper.setup_complete()
    end)

    before_each(function()
        helper.before_each()
        uname_output = nil

        -- Mock io.popen for uname -m
        local original_io_popen = io.popen
        _G.io.popen = function(cmd)
            if cmd == "uname -m" then
                return {
                    read = function(self, fmt)
                        return uname_output
                    end,
                    close = function() end,
                }
            end
            return original_io_popen(cmd)
        end
    end)

    -- Helper to test architecture mapping
    local function test_arch(input, expected)
        uname_output = input
        LocalSend = require("main")
        local instance = helper.create_instance()
        return instance:getDeviceArch()
    end

    describe("64-bit ARM detection", function()
        local test_cases = {
            { "aarch64", "arm64" },
            { "arm64", "arm64" },
            { "aarch64_be", "arm64" },  -- big-endian variant
        }

        for _, tc in ipairs(test_cases) do
            it("maps '" .. tc[1] .. "' to '" .. tc[2] .. "'", function()
                assert.equal(tc[2], test_arch(tc[1]))
            end)
        end
    end)

    describe("32-bit ARM v7 detection", function()
        local test_cases = {
            { "armv7l", "armv7" },   -- common on Kindle PW+
            { "armv7", "armv7" },
            { "armv7hl", "armv7" },  -- hard-float variant
        }

        for _, tc in ipairs(test_cases) do
            it("maps '" .. tc[1] .. "' to '" .. tc[2] .. "'", function()
                assert.equal(tc[2], test_arch(tc[1]))
            end)
        end
    end)

    describe("legacy ARM detection (arm-legacy)", function()
        local test_cases = {
            { "armv5", "arm-legacy" },
            { "armv5tel", "arm-legacy" },  -- Kindle 3/4
            { "armv6l", "arm-legacy" },    -- uses legacy binary
            { "arm", "arm-legacy" },       -- fallback
        }

        for _, tc in ipairs(test_cases) do
            it("maps '" .. tc[1] .. "' to '" .. tc[2] .. "'", function()
                assert.equal(tc[2], test_arch(tc[1]))
            end)
        end
    end)

    describe("unknown architecture handling", function()
        local test_cases = {
            { "x86_64", nil },
            { "i686", nil },
            { "", nil },
        }

        for _, tc in ipairs(test_cases) do
            local desc = tc[1] == "" and "empty output" or "'" .. tc[1] .. "'"
            it("returns nil for " .. desc, function()
                assert.is_nil(test_arch(tc[1]))
            end)
        end

        it("returns nil when uname fails", function()
            assert.is_nil(test_arch(nil))
        end)
    end)

    describe("io.popen failure handling", function()
        it("returns nil when io.popen returns nil", function()
            _G.io.popen = function(cmd)
                if cmd == "uname -m" then
                    return nil
                end
            end

            LocalSend = require("main")
            local instance = helper.create_instance()

            assert.is_nil(instance:getDeviceArch())
        end)
    end)
end)
