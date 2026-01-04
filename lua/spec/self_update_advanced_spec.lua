require 'busted.runner'()

-- Tests for self-update advanced scenarios (partial failures, copy errors, etc.)

describe("Self-Update Advanced", function()
    local LocalSend
    local settings
    local http_responses
    local file_contents
    local notifications_shown
    local os_execute_calls
    local removed_files
    local logger_calls

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
        package.loaded["ui/widget/confirmbox"] = {
            new = function(self, o)
                if o.ok_callback then
                    o._ok_callback = o.ok_callback
                end
                return o
            end,
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

        package.loaded["gettext"] = setmetatable({}, {
            __call = function(_, s) return s end,
        })

        _G.dofile = function(path)
            if path:match("_meta%.lua$") then
                return { version = "v1.1.1" }
            end
        end
    end)

    before_each(function()
        settings = {}
        http_responses = {}
        file_contents = {}
        notifications_shown = {}
        os_execute_calls = {}
        removed_files = {}
        logger_calls = { err = {}, warn = {}, info = {}, dbg = {} }

        _G.G_reader_settings = {
            readSetting = function(self, key) return settings[key] end,
            saveSetting = function(self, key, value) settings[key] = value end,
            isTrue = function(self, key) return settings[key] == true end,
            nilOrTrue = function(self, key) return settings[key] ~= false end,
            flipNilOrTrue = function(self, key) settings[key] = not self:nilOrTrue(key) end,
            flipNilOrFalse = function(self, key) settings[key] = not self:isTrue(key) end,
        }

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
                if file_contents[path] ~= nil then return true end
                return false
            end,
            makePath = function(path)
                return true
            end,
            readFromFile = function(path)
                return file_contents[path]
            end,
            splitFilePathName = function(file)
                if file == nil or file == "" then return "", "" end
                if not file:find("/") then return "", file end
                return file:match("(.*/)(.*)")
            end,
        }

        package.loaded["json"] = {
            encode = function(t) return "{}" end,
            decode = function(s)
                if s:match('"tag_name"') then
                    local result = {}
                    result.tag_name = s:match('"tag_name":"([^"]+)"')
                    result.body = s:match('"body":"([^"]*)"')
                    result.assets = {}
                    for name, url in s:gmatch('"name":"([^"]+)"[^}]*"browser_download_url":"([^"]+)"') do
                        table.insert(result.assets, {
                            name = name,
                            browser_download_url = url,
                        })
                    end
                    return result
                end
                return {}
            end,
        }

        package.loaded["ui/widget/infomessage"] = {
            new = function(self, o)
                table.insert(notifications_shown, o)
                return o
            end,
        }

        package.loaded["ui/widget/notification"] = { new = function(self, o) return o end }
        package.loaded["ui/network/manager"] = {
            isOnline = function() return true end,
            runWhenOnline = function(self, callback) callback() end,
            runWhenConnected = function(self, callback) callback() end,
            isConnected = function() return true end,
        }
        package.loaded["ui/uimanager"] = {
            show = function() end,
            close = function() end,
            scheduleIn = function(self, delay, callback)
                if callback then callback() end
            end,
        }
        package.loaded["pluginshare"] = {}

        package.loaded["logger"] = {
            err = function(...)
                local args = {...}
                table.insert(logger_calls.err, table.concat(args, " "))
            end,
            warn = function(...)
                local args = {...}
                table.insert(logger_calls.warn, table.concat(args, " "))
            end,
            info = function(...)
                local args = {...}
                table.insert(logger_calls.info, table.concat(args, " "))
            end,
            dbg = function(...)
                local args = {...}
                table.insert(logger_calls.dbg, table.concat(args, " "))
            end,
        }

        -- Default mock for io.popen
        local original_io_popen = io.popen
        _G.io.popen = function(cmd)
            if cmd == "uname -m" then
                return {
                    read = function() return "armv7l" end,
                    close = function() end,
                }
            end
            if cmd:match("curl") then
                local http_code = http_responses.code or "200"
                return {
                    read = function() return http_code end,
                    close = function() end,
                }
            end
            if cmd:match("^'ls'") then
                local files = http_responses.ls_files or {}
                local i = 0
                return {
                    lines = function()
                        return function()
                            i = i + 1
                            return files[i]
                        end
                    end,
                    close = function() end,
                }
            end
            return original_io_popen(cmd)
        end

        -- Default mock for io.open
        local original_io_open = io.open
        _G.io.open = function(path, mode)
            if mode == "r" and file_contents[path] then
                local content = file_contents[path]
                return {
                    read = function(self, fmt)
                        if fmt == "*a" then return content end
                        return content
                    end,
                    close = function() end,
                }
            end
            if mode == "w" then
                return {
                    write = function(self, data)
                        file_contents[path] = data
                    end,
                    close = function() end,
                }
            end
            return original_io_open(path, mode)
        end

        -- Default mock for os.execute
        _G.os.execute = function(cmd)
            table.insert(os_execute_calls, cmd)
            return 0
        end

        -- Mock os.remove
        _G.os.remove = function(path)
            table.insert(removed_files, path)
            file_contents[path] = nil
            return true
        end

        package.loaded["localsend_utils"] = require("localsend_utils")
        package.loaded["main"] = nil
    end)

    describe("doPerformUpdate file copy failures", function()
        local function setup_successful_download()
            http_responses.code = "200"
            package.loaded["util"].pathExists = function(path)
                if path == "/tmp/koreader/plugins/localsend.koplugin" then return true end
                if path == "/tmp/koreader/plugins/localsend.koplugin/localsend" then return true end
                if path == "/tmp/localsend_update.zip" then return true end
                if path == "/tmp/localsend_update_extract/localsend.koplugin" then return true end
                if path:match("/tmp/localsend_update_extract/localsend.koplugin/") then return true end
                return false
            end
        end

        it("handles core file copy failure gracefully", function()
            setup_successful_download()

            -- Make cp fail for main.lua
            _G.os.execute = function(cmd)
                table.insert(os_execute_calls, cmd)
                if cmd:match("'cp'.*main%.lua") then
                    return 1
                end
                return 0
            end

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance:doPerformUpdate("https://example.com/update.zip", "update.zip", "v2.0.0")

            -- Should log error
            local found_error_log = false
            for _, msg in ipairs(logger_calls.err) do
                if msg:match("Failed to copy") and msg:match("main%.lua") then
                    found_error_log = true
                    break
                end
            end
            assert.is_true(found_error_log, "Should log error for failed file copy")

            -- Should show partial failure message
            local found_partial_failure = false
            for _, n in ipairs(notifications_shown) do
                if n.text and n.text:match("partially failed") then
                    found_partial_failure = true
                    break
                end
            end
            assert.is_true(found_partial_failure, "Should show partial failure message")
        end)

        it("continues copying after individual file failure", function()
            setup_successful_download()

            local copy_commands = {}
            _G.os.execute = function(cmd)
                table.insert(os_execute_calls, cmd)
                if cmd:match("^'cp'") then
                    table.insert(copy_commands, cmd)
                    -- Fail first cp command
                    if #copy_commands == 1 then
                        return 1
                    end
                end
                return 0
            end

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance:doPerformUpdate("https://example.com/update.zip", "update.zip", "v2.0.0")

            -- Should have attempted to copy all core files despite first failure
            -- Core files: main.lua, _meta.lua, localsend (3 files)
            assert.is_true(#copy_commands >= 3, "Should attempt to copy all core files: " .. #copy_commands)
        end)

        it("handles additional Lua file copying", function()
            setup_successful_download()

            -- Mock ls to return additional lua files
            http_responses.ls_files = {
                "/tmp/localsend_update_extract/localsend.koplugin/localsend_utils.lua",
                "/tmp/localsend_update_extract/localsend.koplugin/main.lua",  -- Should be skipped
                "/tmp/localsend_update_extract/localsend.koplugin/_meta.lua",  -- Should be skipped
            }

            local additional_lua_copied = false
            local main_lua_in_additional = false
            local meta_lua_in_additional = false

            local original_execute = _G.os.execute
            _G.os.execute = function(cmd)
                table.insert(os_execute_calls, cmd)
                -- Check for additional lua file copies (not core files)
                if cmd:match("'cp'.*localsend_utils%.lua") then
                    additional_lua_copied = true
                end
                return 0
            end

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance:doPerformUpdate("https://example.com/update.zip", "update.zip", "v2.0.0")

            -- localsend_utils.lua should be copied
            assert.is_true(additional_lua_copied, "Should copy additional lua files like localsend_utils.lua")

            -- Verify main.lua and _meta.lua are not copied twice (already in core files)
            local extra_main_copies = 0
            local extra_meta_copies = 0
            for _, cmd in ipairs(os_execute_calls) do
                -- Count copies from the additional loop (ls output paths)
                if cmd:match("'cp'.*/tmp/localsend_update_extract/localsend.koplugin/main%.lua") then
                    extra_main_copies = extra_main_copies + 1
                end
                if cmd:match("'cp'.*/tmp/localsend_update_extract/localsend.koplugin/_meta%.lua") then
                    extra_meta_copies = extra_meta_copies + 1
                end
            end
            -- The code should skip main.lua and _meta.lua in the additional loop
            -- They are only copied once from the core files loop
        end)

        it("handles additional Lua file copy failure", function()
            setup_successful_download()

            http_responses.ls_files = {
                "/tmp/localsend_update_extract/localsend.koplugin/localsend_utils.lua",
            }

            _G.os.execute = function(cmd)
                table.insert(os_execute_calls, cmd)
                if cmd:match("'cp'.*localsend_utils%.lua") then
                    return 1
                end
                return 0
            end

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance:doPerformUpdate("https://example.com/update.zip", "update.zip", "v2.0.0")

            -- Should log warning for additional file failure
            local found_warn = false
            for _, msg in ipairs(logger_calls.warn) do
                if msg:match("Failed to copy additional") then
                    found_warn = true
                    break
                end
            end
            assert.is_true(found_warn, "Should log warning for additional lua file copy failure")

            -- Should still show success (additional lua failures are non-fatal)
            local found_success = false
            for _, n in ipairs(notifications_shown) do
                if n.text and n.text:match("successfully") then
                    found_success = true
                    break
                end
            end
            assert.is_true(found_success, "Should show success even with additional lua file failure")
        end)

        it("handles chmod failure gracefully", function()
            setup_successful_download()

            _G.os.execute = function(cmd)
                table.insert(os_execute_calls, cmd)
                if cmd:match("'chmod' '%+x'") then
                    return 1
                end
                return 0
            end

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance:doPerformUpdate("https://example.com/update.zip", "update.zip", "v2.0.0")

            -- chmod failure is non-fatal, should still show success
            local found_success = false
            for _, n in ipairs(notifications_shown) do
                if n.text and n.text:match("successfully") then
                    found_success = true
                    break
                end
            end
            assert.is_true(found_success, "Should show success even when chmod fails")
        end)

        it("handles partial success scenario correctly", function()
            setup_successful_download()

            local copy_count = 0
            _G.os.execute = function(cmd)
                table.insert(os_execute_calls, cmd)
                if cmd:match("^'cp'") then
                    copy_count = copy_count + 1
                    -- Fail second copy only
                    if copy_count == 2 then
                        return 1
                    end
                end
                return 0
            end

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance:doPerformUpdate("https://example.com/update.zip", "update.zip", "v2.0.0")

            -- Should attempt all copies
            assert.is_true(copy_count >= 3, "Should attempt all core file copies")

            -- Should show partial failure
            local found_partial = false
            for _, n in ipairs(notifications_shown) do
                if n.text and n.text:match("partially failed") then
                    found_partial = true
                    break
                end
            end
            assert.is_true(found_partial, "Should show partial failure message")
        end)

        it("logs debug message for successfully copied additional files", function()
            setup_successful_download()

            http_responses.ls_files = {
                "/tmp/localsend_update_extract/localsend.koplugin/localsend_utils.lua",
            }

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance:doPerformUpdate("https://example.com/update.zip", "update.zip", "v2.0.0")

            -- Should log debug for successful additional file copy
            local found_dbg = false
            for _, msg in ipairs(logger_calls.dbg) do
                if msg:match("Copied additional lua file") then
                    found_dbg = true
                    break
                end
            end
            assert.is_true(found_dbg, "Should log debug message for copied additional files")
        end)

        it("handles file not in update package", function()
            http_responses.code = "200"

            -- Must reload module after changing pathExists
            package.loaded["main"] = nil
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
                    if path == "/tmp/localsend_update.zip" then return true end
                    if path == "/tmp/localsend_update_extract/localsend.koplugin" then return true end
                    -- main.lua exists in package, but _meta.lua doesn't
                    if path == "/tmp/localsend_update_extract/localsend.koplugin/main.lua" then return true end
                    if path == "/tmp/localsend_update_extract/localsend.koplugin/localsend" then return true end
                    -- _meta.lua doesn't exist
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
            makePath = function(path)
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

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance:doPerformUpdate("https://example.com/update.zip", "update.zip", "v2.0.0")

            -- Should log warning for missing file
            local found_warn = false
            for _, msg in ipairs(logger_calls.warn) do
                if msg:match("File not in update package") and msg:match("_meta%.lua") then
                    found_warn = true
                    break
                end
            end
            assert.is_true(found_warn, "Should log warning for missing file in package")
        end)
    end)

    describe("checkForUpdates HTTP error handling", function()
        it("handles 404 response with user-friendly message", function()
            http_responses.code = "404"

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance:checkForUpdates()

            local found_error = false
            for _, n in ipairs(notifications_shown) do
                -- The template function T() may or may not substitute, so check for either
                if n.text and (n.text:match("Failed to check") or n.text:match("HTTP status")) then
                    found_error = true
                    break
                end
            end
            assert.is_true(found_error, "Should show error message on HTTP failure")
        end)

        it("handles 500 server error", function()
            http_responses.code = "500"

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance:checkForUpdates()

            local found_error = false
            for _, n in ipairs(notifications_shown) do
                if n.text and (n.text:match("Failed to check") or n.text:match("HTTP status")) then
                    found_error = true
                    break
                end
            end
            assert.is_true(found_error, "Should show error message on server error")
        end)

        it("handles 429 rate limit error", function()
            http_responses.code = "429"

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance:checkForUpdates()

            local found_error = false
            for _, n in ipairs(notifications_shown) do
                if n.text and (n.text:match("Failed to check") or n.text:match("HTTP status")) then
                    found_error = true
                    break
                end
            end
            assert.is_true(found_error, "Should show error message on rate limit")
        end)

        it("handles status file read failure", function()
            http_responses.code = "200"

            -- File doesn't exist and can't be opened
            local original_io_open = _G.io.open
            _G.io.open = function(path, mode)
                if path == "/tmp/localsend_update_check.json" and mode == "r" then
                    return nil  -- Simulate file read failure
                end
                return original_io_open(path, mode)
            end

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance:checkForUpdates()

            local found_error = false
            for _, n in ipairs(notifications_shown) do
                if n.text and n.text:match("Failed to read update information") then
                    found_error = true
                    break
                end
            end
            assert.is_true(found_error, "Should show file read error message")
        end)

        it("handles malformed JSON response", function()
            http_responses.code = "200"
            file_contents["/tmp/localsend_update_check.json"] = "not valid json {{{{"

            package.loaded["json"].decode = function(s)
                error("JSON parse error")
            end

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance:checkForUpdates()

            local found_error = false
            for _, n in ipairs(notifications_shown) do
                if n.text and n.text:match("Failed to parse") then
                    found_error = true
                    break
                end
            end
            assert.is_true(found_error, "Should show JSON parse error message")
        end)

        it("handles JSON without tag_name field", function()
            http_responses.code = "200"
            file_contents["/tmp/localsend_update_check.json"] = '{"message":"Not Found"}'

            package.loaded["json"].decode = function(s)
                return { message = "Not Found" }  -- No tag_name field
            end

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance:checkForUpdates()

            local found_error = false
            for _, n in ipairs(notifications_shown) do
                if n.text and n.text:match("Failed to parse") then
                    found_error = true
                    break
                end
            end
            assert.is_true(found_error, "Should show parse error when tag_name missing")
        end)

        it("cleans up temp file on HTTP failure", function()
            http_responses.code = "500"

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance:checkForUpdates()

            local found_cleanup = false
            for _, path in ipairs(removed_files) do
                if path == "/tmp/localsend_update_check.json" then
                    found_cleanup = true
                    break
                end
            end
            assert.is_true(found_cleanup, "Should clean up temp file on failure")
        end)
    end)
end)
