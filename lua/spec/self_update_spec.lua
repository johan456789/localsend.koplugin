require 'busted.runner'()

-- Tests for self-update functionality

describe("Self-Update", function()
    local LocalSend
    local settings
    local http_responses
    local file_contents
    local notifications_shown
    local os_execute_calls
    local removed_files

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
        package.loaded["ui/widget/confirmbox"] = {
            new = function(self, o)
                -- Auto-confirm for testing
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

        package.loaded["logger"] = {
            err = function() end,
            warn = function() end,
            info = function() end,
            dbg = function() end,
        }
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

        _G.G_reader_settings = {
            readSetting = function(self, key) return settings[key] end,
            saveSetting = function(self, key, value) settings[key] = value end,
            isTrue = function(self, key) return settings[key] == true end,
            nilOrTrue = function(self, key) return settings[key] ~= false end,
            flipNilOrTrue = function(self, key) settings[key] = not self:nilOrTrue(key) end,
            flipNilOrFalse = function(self, key) settings[key] = not self:isTrue(key) end,
        }

        package.loaded["util"] = {
            args = function(t)
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
        }

        package.loaded["json"] = {
            encode = function(t) return "{}" end,
            decode = function(s)
                -- Parse release JSON for tests
                if s:match('"tag_name"') then
                    local result = {}
                    result.tag_name = s:match('"tag_name":"([^"]+)"')
                    result.body = s:match('"body":"([^"]*)"')
                    result.assets = {}

                    -- Parse assets array
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

        package.loaded["ui/uimanager"] = {
            show = function() end,
            close = function() end,
            scheduleIn = function(self, delay, callback)
                -- Execute immediately for testing
                if callback then callback() end
            end,
        }

        -- Mock io.popen for curl and uname
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
            if cmd:match("^ls ") then
                return {
                    lines = function()
                        return function() return nil end
                    end,
                    close = function() end,
                }
            end
            return original_io_popen(cmd)
        end

        -- Mock io.open
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

        -- Mock os.execute
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

    describe("checkForUpdates", function()
        it("shows 'up to date' when current version is latest", function()
            -- Set up response file
            file_contents["/tmp/localsend_update_check.json"] = [[
                {"tag_name":"v1.1.1","body":"Release notes"}
            ]]
            http_responses.code = "200"

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance:checkForUpdates()

            local found_up_to_date = false
            for _, n in ipairs(notifications_shown) do
                if n.text and n.text:match("up to date") then
                    found_up_to_date = true
                    break
                end
            end
            assert.is_true(found_up_to_date, "Should show up to date message")
        end)

        it("shows 'up to date' when current version is newer", function()
            file_contents["/tmp/localsend_update_check.json"] = [[
                {"tag_name":"v1.0.0","body":"Old version"}
            ]]
            http_responses.code = "200"

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance:checkForUpdates()

            local found_up_to_date = false
            for _, n in ipairs(notifications_shown) do
                if n.text and n.text:match("up to date") then
                    found_up_to_date = true
                    break
                end
            end
            assert.is_true(found_up_to_date, "Should show up to date when current is newer")
        end)

        it("shows error on HTTP failure", function()
            http_responses.code = "404"

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance:checkForUpdates()

            local found_error = false
            for _, n in ipairs(notifications_shown) do
                if n.text and n.text:match("Failed to check") then
                    found_error = true
                    break
                end
            end
            assert.is_true(found_error, "Should show error on HTTP failure")
        end)

        it("shows update available with matching asset", function()
            file_contents["/tmp/localsend_update_check.json"] = [[
                {"tag_name":"v2.0.0","body":"New features","assets":[
                    {"name":"localsend-koplugin-armv7.zip","browser_download_url":"https://example.com/armv7.zip"}
                ]}
            ]]
            http_responses.code = "200"

            -- Track ConfirmBox creation
            local confirm_shown = false
            package.loaded["ui/widget/confirmbox"] = {
                new = function(self, o)
                    confirm_shown = true
                    -- Check that the dialog text references the new version (with %1 placeholder or actual version)
                    assert.truthy(o.text:match("v2%.0%.0") or o.text:match("Update") or o.text:match("%%1"))
                    return o
                end,
            }

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance:checkForUpdates()

            assert.is_true(confirm_shown, "Should show confirmation dialog for update")
        end)

        it("shows info message when no matching asset for architecture", function()
            file_contents["/tmp/localsend_update_check.json"] = [[
                {"tag_name":"v2.0.0","body":"New features","assets":[
                    {"name":"localsend-koplugin-arm64.zip","browser_download_url":"https://example.com/arm64.zip"}
                ]}
            ]]
            http_responses.code = "200"

            -- Device is armv7 but only arm64 asset available

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance:checkForUpdates()

            -- Should show an info message about update available but no package
            -- or auto-update not available
            local found_update_info = false
            for _, n in ipairs(notifications_shown) do
                if n.text and (n.text:match("no package") or n.text:match("Update available") or n.text:match("Auto%-update not available") or n.text:match("architecture")) then
                    found_update_info = true
                    break
                end
            end
            assert.is_true(found_update_info, "Should indicate update info with architecture note")
        end)
    end)

    describe("performUpdate", function()
        it("stops server if running before update", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local stop_called = false
            instance.isRunning = function() return true end
            instance.stopServer = function()
                stop_called = true
                return true
            end
            instance.doPerformUpdate = function() end

            instance:performUpdate("https://example.com/update.zip", "update.zip", "v2.0.0")

            assert.is_true(stop_called, "Should stop server before update")
        end)
    end)

    describe("doPerformUpdate", function()
        it("cleans up on download failure", function()
            http_responses.code = "500"

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance:doPerformUpdate("https://example.com/update.zip", "update.zip", "v2.0.0")

            -- Should show error
            local found_error = false
            for _, n in ipairs(notifications_shown) do
                if n.text and n.text:match("Download failed") then
                    found_error = true
                    break
                end
            end
            assert.is_true(found_error, "Should show download error")

            -- Should clean up temp file
            local found_cleanup = false
            for _, path in ipairs(removed_files) do
                if path == "/tmp/localsend_update.zip" then
                    found_cleanup = true
                    break
                end
            end
            assert.is_true(found_cleanup, "Should clean up temp zip")
        end)

        it("extracts and copies files on success", function()
            http_responses.code = "200"

            -- Simulate successful download and extraction
            local original_pathExists = package.loaded["util"].pathExists
            package.loaded["util"].pathExists = function(path)
                if path == "/tmp/localsend_update.zip" then return true end
                if path == "/tmp/localsend_update_extract/localsend.koplugin" then return true end
                if path:match("/tmp/localsend_update_extract/localsend.koplugin/") then return true end
                return original_pathExists(path)
            end

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance:doPerformUpdate("https://example.com/update.zip", "update.zip", "v2.0.0")

            -- Should have run unzip
            local found_unzip = false
            for _, cmd in ipairs(os_execute_calls) do
                if cmd:match("unzip") then
                    found_unzip = true
                    break
                end
            end
            assert.is_true(found_unzip, "Should run unzip")

            -- Should have copied files
            local found_cp = false
            for _, cmd in ipairs(os_execute_calls) do
                if cmd:match("^'cp'") then
                    found_cp = true
                    break
                end
            end
            assert.is_true(found_cp, "Should copy files")

            -- Should make binary executable
            local found_chmod = false
            for _, cmd in ipairs(os_execute_calls) do
                if cmd:match("'chmod' '%+x'") and cmd:match("localsend") then
                    found_chmod = true
                    break
                end
            end
            assert.is_true(found_chmod, "Should make binary executable")
        end)

        it("shows success message after update", function()
            http_responses.code = "200"

            local original_pathExists = package.loaded["util"].pathExists
            package.loaded["util"].pathExists = function(path)
                if path == "/tmp/localsend_update.zip" then return true end
                if path == "/tmp/localsend_update_extract/localsend.koplugin" then return true end
                if path:match("/tmp/localsend_update_extract/") then return true end
                return original_pathExists(path)
            end

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance:doPerformUpdate("https://example.com/update.zip", "update.zip", "v2.0.0")

            local found_success = false
            for _, n in ipairs(notifications_shown) do
                if n.text and n.text:match("successfully") then
                    found_success = true
                    break
                end
            end
            assert.is_true(found_success, "Should show success message")
        end)

        it("handles extraction failure gracefully", function()
            http_responses.code = "200"

            -- Zip exists but extraction fails
            local original_pathExists = package.loaded["util"].pathExists
            package.loaded["util"].pathExists = function(path)
                if path == "/tmp/localsend_update.zip" then return true end
                return original_pathExists(path)
            end

            _G.os.execute = function(cmd)
                table.insert(os_execute_calls, cmd)
                if cmd:match("unzip") then
                    return 1 -- Fail extraction
                end
                return 0
            end

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance:doPerformUpdate("https://example.com/update.zip", "update.zip", "v2.0.0")

            local found_error = false
            for _, n in ipairs(notifications_shown) do
                if n.text and n.text:match("Failed to extract") then
                    found_error = true
                    break
                end
            end
            assert.is_true(found_error, "Should show extraction error")
        end)

        it("handles invalid package structure", function()
            http_responses.code = "200"

            -- Zip exists, extraction succeeds, but wrong structure
            local original_pathExists = package.loaded["util"].pathExists
            package.loaded["util"].pathExists = function(path)
                if path == "/tmp/localsend_update.zip" then return true end
                -- localsend.koplugin folder doesn't exist
                if path == "/tmp/localsend_update_extract/localsend.koplugin" then return false end
                return original_pathExists(path)
            end

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance:doPerformUpdate("https://example.com/update.zip", "update.zip", "v2.0.0")

            local found_error = false
            for _, n in ipairs(notifications_shown) do
                if n.text and n.text:match("Invalid update package") then
                    found_error = true
                    break
                end
            end
            assert.is_true(found_error, "Should show invalid package error")
        end)
    end)

    describe("version comparison integration", function()
        it("correctly identifies older version needing update", function()
            -- Override _meta to report older version
            _G.dofile = function(path)
                if path:match("_meta%.lua$") then
                    return { version = "v1.0.0" }
                end
            end

            file_contents["/tmp/localsend_update_check.json"] = [[
                {"tag_name":"v1.1.0","body":"Bug fixes","assets":[
                    {"name":"localsend-koplugin-armv7.zip","browser_download_url":"https://example.com/armv7.zip"}
                ]}
            ]]
            http_responses.code = "200"

            local confirm_shown = false
            package.loaded["ui/widget/confirmbox"] = {
                new = function(self, o)
                    confirm_shown = true
                    return o
                end,
            }

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance:checkForUpdates()

            assert.is_true(confirm_shown, "Should offer update from 1.0.0 to 1.1.0")
        end)
    end)
end)
