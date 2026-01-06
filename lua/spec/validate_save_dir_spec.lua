require 'busted.runner'()
local helper = require("spec.test_helper")

-- Tests for validateSaveDir - validates directory is usable for saving files

describe("validateSaveDir", function()
    local LocalSend
    local path_exists_map
    local writable_paths

    setup(function()
        helper.setup_complete()
    end)

    before_each(function()
        helper.before_each()
        path_exists_map = {
            ["/tmp/koreader/plugins/localsend.koplugin"] = true,
            ["/tmp/koreader/plugins/localsend.koplugin/localsend"] = true,
        }
        writable_paths = {}
        _G._test_makePath_results = nil

        -- Custom pathExists for this test
        package.loaded["util"].pathExists = function(path)
            if path_exists_map[path] ~= nil then return path_exists_map[path] end
            return false
        end

        -- Custom makePath for this test
        package.loaded["util"].makePath = function(path)
            if _G._test_makePath_results and _G._test_makePath_results[path] ~= nil then
                if not _G._test_makePath_results[path] then
                    return nil, "Failed to create directory"
                end
            end
            path_exists_map[path] = true
            return true
        end

        -- Mock io.open for write test
        local original_io_open = io.open
        _G.io.open = function(path, mode)
            if mode == "w" then
                if path:match("%.localsend_write_test$") then
                    local dir = path:match("^(.+)/[^/]+$")
                    if writable_paths[dir] then
                        return { close = function() end }
                    end
                    return nil
                end
            end
            return original_io_open(path, mode)
        end

        helper.mock_os_remove()
    end)

    describe("path validation", function()
        it("rejects nil path", function()
            local instance = helper.create_instance()
            local valid, err = instance:validateSaveDir(nil)
            assert.is_false(valid)
            assert.is_not_nil(err)
        end)

        it("rejects empty path", function()
            local instance = helper.create_instance()
            local valid, err = instance:validateSaveDir("")
            assert.is_false(valid)
            assert.is_not_nil(err)
        end)

        it("rejects relative paths", function()
            local instance = helper.create_instance()
            local valid, err = instance:validateSaveDir("relative/path")
            assert.is_false(valid)
            assert.is_not_nil(err)
            assert.truthy(err:match("absolute path"))
        end)

        it("rejects paths with command substitution", function()
            local instance = helper.create_instance()

            local valid, err = instance:validateSaveDir("/path/$(whoami)")
            assert.is_false(valid)

            valid, err = instance:validateSaveDir("/path/`id`")
            assert.is_false(valid)
        end)
    end)

    describe("directory existence", function()
        it("accepts existing writable directory", function()
            path_exists_map["/mnt/us/documents"] = true
            writable_paths["/mnt/us/documents"] = true

            local instance = helper.create_instance()
            local valid, err = instance:validateSaveDir("/mnt/us/documents")
            assert.is_true(valid)
            assert.is_nil(err)
        end)

        it("creates non-existent directory if possible", function()
            path_exists_map["/mnt/us/newdir"] = false
            writable_paths["/mnt/us/newdir"] = true

            local instance = helper.create_instance()
            local valid, err = instance:validateSaveDir("/mnt/us/newdir")
            assert.is_true(valid)
            assert.is_true(path_exists_map["/mnt/us/newdir"], "Path should exist after makePath")
        end)

        it("rejects directory that cannot be created", function()
            path_exists_map["/readonly/newdir"] = false
            _G._test_makePath_results = { ["/readonly/newdir"] = false }

            local instance = helper.create_instance()
            local valid, err = instance:validateSaveDir("/readonly/newdir")
            assert.is_false(valid)
            assert.truthy(err:match("could not be created"))
        end)
    end)

    describe("write permission check", function()
        it("rejects directory that is not writable", function()
            path_exists_map["/readonly/dir"] = true
            writable_paths["/readonly/dir"] = false

            local instance = helper.create_instance()
            local valid, err = instance:validateSaveDir("/readonly/dir")
            assert.is_false(valid)
            assert.truthy(err:match("not writable"))
        end)

        it("cleans up test file after successful check", function()
            path_exists_map["/mnt/us/documents"] = true
            writable_paths["/mnt/us/documents"] = true

            local instance = helper.create_instance()
            instance:validateSaveDir("/mnt/us/documents")

            -- Should have tried to remove the test file
            local found_cleanup = false
            for _, path in ipairs(helper.state.removed_files) do
                if path:match("%.localsend_write_test$") then
                    found_cleanup = true
                    break
                end
            end
            assert.is_true(found_cleanup, "Test file should be cleaned up")
        end)
    end)
end)
