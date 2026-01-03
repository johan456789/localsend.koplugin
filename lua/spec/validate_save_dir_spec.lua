require 'busted.runner'()

-- Tests for validateSaveDir - validates directory is usable for saving files

describe("validateSaveDir", function()
    local LocalSend
    local path_exists_map
    local writable_paths
    local mkdir_results
    local os_execute_calls

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
        package.loaded["ui/widget/inputdialog"] = { new = function(self, o) return o end }
        package.loaded["ui/widget/pathchooser"] = { new = function(self, o) return o end }
        package.loaded["ui/network/manager"] = { isOnline = function() return true end }
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
        path_exists_map = {
            ["/tmp/koreader/plugins/localsend.koplugin"] = true,
            ["/tmp/koreader/plugins/localsend.koplugin/localsend"] = true,
        }
        writable_paths = {}
        mkdir_results = {}
        os_execute_calls = {}

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
                if path_exists_map[path] ~= nil then
                    return path_exists_map[path]
                end
                return false
            end,
            makePath = function(path)
                -- Check if makePath should fail for this path
                if _G._test_makePath_results and _G._test_makePath_results[path] ~= nil then
                    if not _G._test_makePath_results[path] then
                        return nil, "Failed to create directory"
                    end
                end
                -- Simulate success - mark path as existing
                path_exists_map[path] = true
                return true
            end,
            readFromFile = function(path)
                return nil
            end,
            splitFilePathName = function(file)
                if file == nil or file == "" then return "", "" end
                if not file:find("/") then return "", file end
                return file:match("(.*/)(.*)")
            end,
        }

        -- Mock os.execute for mkdir
        local original_os_execute = os.execute
        _G.os.execute = function(cmd)
            table.insert(os_execute_calls, cmd)
            -- Check if it's a mkdir command
            local path = cmd:match("mkdir %-p '([^']+)'")
            if path and mkdir_results[path] ~= nil then
                return mkdir_results[path]
            end
            return 0 -- Default success
        end

        -- Mock io.open for write test
        local original_io_open = io.open
        _G.io.open = function(path, mode)
            if mode == "w" then
                -- Check if path is in writable_paths or ends with .localsend_write_test
                if path:match("%.localsend_write_test$") then
                    local dir = path:match("^(.+)/[^/]+$")
                    if writable_paths[dir] then
                        return {
                            close = function() end,
                        }
                    end
                    return nil -- Not writable
                end
            end
            return original_io_open(path, mode)
        end

        -- Mock os.remove
        _G.os.remove = function() return true end

        package.loaded["main"] = nil
    end)

    describe("path validation", function()
        it("rejects nil path", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local valid, err = instance:validateSaveDir(nil)
            assert.is_false(valid)
            assert.is_not_nil(err)
        end)

        it("rejects empty path", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local valid, err = instance:validateSaveDir("")
            assert.is_false(valid)
            assert.is_not_nil(err)
        end)

        it("rejects relative paths", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local valid, err = instance:validateSaveDir("relative/path")
            assert.is_false(valid)
            assert.is_not_nil(err)
            assert.truthy(err:match("absolute path"))
        end)

        it("rejects paths with command substitution", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

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

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local valid, err = instance:validateSaveDir("/mnt/us/documents")
            assert.is_true(valid)
            assert.is_nil(err)
        end)

        it("creates non-existent directory if possible", function()
            path_exists_map["/mnt/us/newdir"] = false
            writable_paths["/mnt/us/newdir"] = true

            -- makePath will mark the path as existing when called (in our mock)

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local valid, err = instance:validateSaveDir("/mnt/us/newdir")
            assert.is_true(valid)

            -- Verify the path now exists (makePath mock marks it as existing)
            assert.is_true(path_exists_map["/mnt/us/newdir"], "Path should exist after makePath")
        end)

        it("rejects directory that cannot be created", function()
            path_exists_map["/readonly/newdir"] = false
            -- Mark this path to fail in makePath
            _G._test_makePath_results = { ["/readonly/newdir"] = false }

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local valid, err = instance:validateSaveDir("/readonly/newdir")
            assert.is_false(valid)
            assert.truthy(err:match("could not be created"))

            _G._test_makePath_results = nil
        end)
    end)

    describe("write permission check", function()
        it("rejects directory that is not writable", function()
            path_exists_map["/readonly/dir"] = true
            writable_paths["/readonly/dir"] = false -- Not writable

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local valid, err = instance:validateSaveDir("/readonly/dir")
            assert.is_false(valid)
            assert.truthy(err:match("not writable"))
        end)

        it("cleans up test file after successful check", function()
            path_exists_map["/mnt/us/documents"] = true
            writable_paths["/mnt/us/documents"] = true

            local removed_files = {}
            _G.os.remove = function(path)
                table.insert(removed_files, path)
                return true
            end

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance:validateSaveDir("/mnt/us/documents")

            -- Should have tried to remove the test file
            local found_cleanup = false
            for _, path in ipairs(removed_files) do
                if path:match("%.localsend_write_test$") then
                    found_cleanup = true
                    break
                end
            end
            assert.is_true(found_cleanup, "Test file should be cleaned up")
        end)
    end)
end)
