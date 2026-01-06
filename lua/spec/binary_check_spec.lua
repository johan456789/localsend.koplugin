require 'busted.runner'()
local helper = require("spec.test_helper")

-- Tests for binary existence check behavior

describe("Binary Existence Check", function()
    setup(function()
        helper.setup_complete()
    end)

    before_each(function()
        helper.before_each()
    end)

    -- Helper to set up util mock with specific binary existence
    local function mock_binary_exists(exists)
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
                if path == "/tmp/koreader/plugins/localsend.koplugin/localsend" then return exists end
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
    end

    describe("when binary is missing", function()
        before_each(function()
            mock_binary_exists(false)
        end)

        it("returns disabled module", function()
            local result = require("main")

            assert.is_table(result)
            assert.is_true(result.disabled, "Module should be disabled when binary missing")
        end)

        it("has only disabled field when binary missing", function()
            local result = require("main")

            -- Should only have the disabled field
            local count = 0
            for _ in pairs(result) do
                count = count + 1
            end
            assert.equal(1, count, "Should have exactly 1 field (disabled)")
            assert.is_true(result.disabled)
        end)
    end)

    describe("when binary exists", function()
        before_each(function()
            mock_binary_exists(true)
        end)

        it("returns full module", function()
            local result = require("main")

            assert.is_nil(result.disabled, "Module should not be disabled when binary exists")
            assert.is_not_nil(result.name, "Module should have name field")
            assert.equal("LocalSend", result.name)
        end)

        -- Parametrized tests for required methods
        local required_methods = { "init", "start", "isRunning" }

        for _, method in ipairs(required_methods) do
            it("has " .. method .. " method", function()
                local result = require("main")
                assert.is_function(result[method], "Module should have " .. method .. " method")
            end)
        end
    end)
end)
