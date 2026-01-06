require 'busted.runner'()
local helper = require("spec.test_helper")

-- Tests for self-update functionality

describe("Self-Update", function()
    local LocalSend
    local http_responses
    local file_contents
    local logger

    before_each(function()
        helper.setup_complete({ capture_logs = true })
        logger = package.loaded["logger"]
        helper.reset_state()
        package.loaded["main"] = nil
        http_responses = { code = "200" }
        file_contents = {}

        -- Extend util.pathExists to check file_contents
        package.loaded["util"].pathExists = function(path)
            if path == "/tmp/koreader/plugins/localsend.koplugin" then return true end
            if path == "/tmp/koreader/plugins/localsend.koplugin/localsend" then return true end
            if file_contents[path] ~= nil then return true end
            return false
        end

        -- Override util.readFromFile to read from file_contents
        package.loaded["util"].readFromFile = function(path)
            return file_contents[path]
        end

        -- Custom json decode for release parsing
        package.loaded["json"].decode = function(s)
            if s:match('"tag_name"') then
                local result = { assets = {} }
                result.tag_name = s:match('"tag_name":"([^"]+)"')
                result.body = s:match('"body":"([^"]*)"')
                for name, url in s:gmatch('"name":"([^"]+)"[^}]*"browser_download_url":"([^"]+)"') do
                    table.insert(result.assets, { name = name, browser_download_url = url })
                end
                return result
            end
            return {}
        end

        -- Mock io.popen for curl and uname
        local original_io_popen = io.popen
        _G.io.popen = function(cmd)
            if cmd == "uname -m" then
                return { read = function() return "armv7l" end, close = function() end }
            end
            if cmd:match("curl") then
                return { read = function() return http_responses.code end, close = function() end }
            end
            if cmd:match("^'ls'") then
                local files = http_responses.ls_files or {}
                local i = 0
                return {
                    lines = function()
                        return function() i = i + 1; return files[i] end
                    end,
                    close = function() end,
                }
            end
            return original_io_popen(cmd)
        end

        -- Mock io.open for file_contents
        local original_io_open = io.open
        _G.io.open = function(path, mode)
            if mode == "r" and file_contents[path] then
                local content = file_contents[path]
                return {
                    read = function(self, fmt) return content end,
                    close = function() end,
                }
            end
            if mode == "w" then
                return {
                    write = function(self, data) file_contents[path] = data end,
                    close = function() end,
                }
            end
            return original_io_open(path, mode)
        end

        helper.mock_os_execute()
        helper.mock_os_remove()
    end)

    -- Helper to setup successful download scenario
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

    -- =======================================================================
    -- checkForUpdates
    -- =======================================================================
    describe("checkForUpdates", function()
        local up_to_date_cases = {
            { "v1.1.1", "same version" },
            { "v1.0.0", "older version" },
        }

        for _, tc in ipairs(up_to_date_cases) do
            it("shows 'up to date' when remote is " .. tc[2], function()
                file_contents["/tmp/localsend_update_check.json"] = string.format(
                    '{"tag_name":"%s","body":"Release notes"}', tc[1])

                local instance = helper.create_instance()
                instance:checkForUpdates()

                assert.is_truthy(helper.find_notification("up to date"))
            end)
        end

        local http_error_cases = {
            { "404", "not found" },
            { "500", "server error" },
            { "429", "rate limit" },
        }

        for _, tc in ipairs(http_error_cases) do
            it("shows error on HTTP " .. tc[1] .. " (" .. tc[2] .. ")", function()
                http_responses.code = tc[1]

                local instance = helper.create_instance()
                instance:checkForUpdates()

                local err = helper.find_notification("Failed to check") or
                           helper.find_notification("HTTP status")
                assert.is_truthy(err, "Should show error for HTTP " .. tc[1])
            end)
        end

        it("shows update available with matching asset", function()
            file_contents["/tmp/localsend_update_check.json"] = [[
                {"tag_name":"v2.0.0","body":"New features","assets":[
                    {"name":"localsend-koplugin-armv7.zip","browser_download_url":"https://example.com/armv7.zip"}
                ]}
            ]]

            local confirm_shown = false
            package.loaded["ui/widget/confirmbox"] = {
                new = function(self, o)
                    confirm_shown = true
                    assert.truthy(o.text:match("v2%.0%.0") or o.text:match("Update") or o.text:match("%%1"))
                    return o
                end,
            }

            local instance = helper.create_instance()
            instance:checkForUpdates()

            assert.is_true(confirm_shown, "Should show confirmation dialog")
        end)

        it("shows info when no matching asset for architecture", function()
            file_contents["/tmp/localsend_update_check.json"] = [[
                {"tag_name":"v2.0.0","body":"New features","assets":[
                    {"name":"localsend-koplugin-arm64.zip","browser_download_url":"https://example.com/arm64.zip"}
                ]}
            ]]

            local instance = helper.create_instance()
            instance:checkForUpdates()

            local info = helper.find_notification("no package") or
                        helper.find_notification("Update available") or
                        helper.find_notification("Auto%-update not available") or
                        helper.find_notification("architecture")
            assert.is_truthy(info, "Should indicate update info with architecture note")
        end)

        it("handles status file read failure", function()
            local original_io_open = _G.io.open
            _G.io.open = function(path, mode)
                if path == "/tmp/localsend_update_check.json" and mode == "r" then
                    return nil
                end
                return original_io_open(path, mode)
            end

            local instance = helper.create_instance()
            instance:checkForUpdates()

            assert.is_truthy(helper.find_notification("Failed to read update information"))
        end)

        it("handles malformed JSON response", function()
            file_contents["/tmp/localsend_update_check.json"] = "not valid json {{{{"
            package.loaded["json"].decode = function(s) error("JSON parse error") end

            local instance = helper.create_instance()
            instance:checkForUpdates()

            assert.is_truthy(helper.find_notification("Failed to parse"))
        end)

        it("handles JSON without tag_name field", function()
            file_contents["/tmp/localsend_update_check.json"] = '{"message":"Not Found"}'
            package.loaded["json"].decode = function(s) return { message = "Not Found" } end

            local instance = helper.create_instance()
            instance:checkForUpdates()

            assert.is_truthy(helper.find_notification("Failed to parse"))
        end)

        it("cleans up temp file on HTTP failure", function()
            http_responses.code = "500"

            local instance = helper.create_instance()
            instance:checkForUpdates()

            local cleaned = false
            for _, path in ipairs(helper.state.removed_files) do
                if path == "/tmp/localsend_update_check.json" then cleaned = true; break end
            end
            assert.is_true(cleaned, "Should clean up temp file")
        end)

        it("uses NetworkMgr:runWhenOnline", function()
            local run_when_online_called = false
            package.loaded["ui/network/manager"] = {
                isOnline = function() return true end,
                runWhenOnline = function(self, callback)
                    run_when_online_called = true
                end,
            }

            local instance = helper.create_instance()
            instance:checkForUpdates()

            assert.is_true(run_when_online_called)
        end)

        it("does NOT show manual 'No network' error when offline", function()
            package.loaded["ui/network/manager"] = {
                isOnline = function() return false end,
                runWhenOnline = function(self, callback) end,
            }

            helper.state.notifications_shown = {}
            local instance = helper.create_instance()
            instance:checkForUpdates()

            assert.is_nil(helper.find_notification("No network connection"))
        end)
    end)

    -- =======================================================================
    -- performUpdate
    -- =======================================================================
    describe("performUpdate", function()
        it("stops server if running before update", function()
            local stop_called = false
            local instance = helper.create_instance()
            instance.isRunning = function() return true end
            instance.stopServer = function() stop_called = true; return true end
            instance.doPerformUpdate = function() end

            instance:performUpdate("https://example.com/update.zip", "update.zip", "v2.0.0")

            assert.is_true(stop_called)
        end)
    end)

    -- =======================================================================
    -- doPerformUpdate
    -- =======================================================================
    describe("doPerformUpdate", function()
        it("cleans up on download failure", function()
            http_responses.code = "500"

            local instance = helper.create_instance()
            instance:doPerformUpdate("https://example.com/update.zip", "update.zip", "v2.0.0")

            assert.is_truthy(helper.find_notification("Download failed"))

            local cleaned = false
            for _, path in ipairs(helper.state.removed_files) do
                if path == "/tmp/localsend_update.zip" then cleaned = true; break end
            end
            assert.is_true(cleaned, "Should clean up temp zip")
        end)

        it("extracts and copies files on success", function()
            setup_successful_download()

            local instance = helper.create_instance()
            instance:doPerformUpdate("https://example.com/update.zip", "update.zip", "v2.0.0")

            assert.is_truthy(helper.find_execute_call("unzip"), "Should run unzip")
            assert.is_truthy(helper.find_execute_call("^'cp'"), "Should copy files")
            assert.is_truthy(helper.find_execute_call("'chmod' '%+x'"), "Should make binary executable")
        end)

        it("shows success message after update", function()
            setup_successful_download()

            local instance = helper.create_instance()
            instance:doPerformUpdate("https://example.com/update.zip", "update.zip", "v2.0.0")

            assert.is_truthy(helper.find_notification("successfully"))
        end)

        it("handles extraction failure gracefully", function()
            http_responses.code = "200"
            package.loaded["util"].pathExists = function(path)
                if path == "/tmp/koreader/plugins/localsend.koplugin" then return true end
                if path == "/tmp/koreader/plugins/localsend.koplugin/localsend" then return true end
                if path == "/tmp/localsend_update.zip" then return true end
                return false
            end

            helper.mock_os_execute(function(cmd)
                if cmd:match("unzip") then return 1 end
                return 0
            end)

            local instance = helper.create_instance()
            instance:doPerformUpdate("https://example.com/update.zip", "update.zip", "v2.0.0")

            assert.is_truthy(helper.find_notification("Failed to extract"))
        end)

        it("handles invalid package structure", function()
            http_responses.code = "200"
            package.loaded["util"].pathExists = function(path)
                if path == "/tmp/koreader/plugins/localsend.koplugin" then return true end
                if path == "/tmp/koreader/plugins/localsend.koplugin/localsend" then return true end
                if path == "/tmp/localsend_update.zip" then return true end
                if path == "/tmp/localsend_update_extract/localsend.koplugin" then return false end
                return false
            end

            local instance = helper.create_instance()
            instance:doPerformUpdate("https://example.com/update.zip", "update.zip", "v2.0.0")

            assert.is_truthy(helper.find_notification("Invalid update package"))
        end)

        it("handles core file copy failure gracefully", function()
            setup_successful_download()

            helper.mock_os_execute(function(cmd)
                if cmd:match("'cp'.*main%.lua") then return 1 end
                return 0
            end)

            local instance = helper.create_instance()
            instance:doPerformUpdate("https://example.com/update.zip", "update.zip", "v2.0.0")

            local found_error = false
            for _, msg in ipairs(logger.calls.err) do
                if msg:match("Failed to copy") and msg:match("main%.lua") then
                    found_error = true; break
                end
            end
            assert.is_true(found_error, "Should log error for failed file copy")
            assert.is_truthy(helper.find_notification("partially failed"))
        end)

        it("continues copying after individual file failure", function()
            setup_successful_download()

            local copy_commands = {}
            helper.mock_os_execute(function(cmd)
                if cmd:match("^'cp'") then
                    table.insert(copy_commands, cmd)
                    if #copy_commands == 1 then return 1 end
                end
                return 0
            end)

            local instance = helper.create_instance()
            instance:doPerformUpdate("https://example.com/update.zip", "update.zip", "v2.0.0")

            assert.is_true(#copy_commands >= 3, "Should attempt all core files")
        end)

        it("handles additional Lua file copying", function()
            setup_successful_download()
            http_responses.ls_files = {
                "/tmp/localsend_update_extract/localsend.koplugin/localsend_utils.lua",
            }

            local instance = helper.create_instance()
            instance:doPerformUpdate("https://example.com/update.zip", "update.zip", "v2.0.0")

            assert.is_truthy(helper.find_execute_call("localsend_utils%.lua"))
        end)

        it("handles additional Lua file copy failure", function()
            setup_successful_download()
            http_responses.ls_files = {
                "/tmp/localsend_update_extract/localsend.koplugin/localsend_utils.lua",
            }

            helper.mock_os_execute(function(cmd)
                if cmd:match("'cp'.*localsend_utils%.lua") then return 1 end
                return 0
            end)

            local instance = helper.create_instance()
            instance:doPerformUpdate("https://example.com/update.zip", "update.zip", "v2.0.0")

            local found_warn = false
            for _, msg in ipairs(logger.calls.warn) do
                if msg:match("Failed to copy additional") then found_warn = true; break end
            end
            assert.is_true(found_warn)
            assert.is_truthy(helper.find_notification("successfully"), "Should still show success")
        end)

        it("handles chmod failure gracefully", function()
            setup_successful_download()

            helper.mock_os_execute(function(cmd)
                if cmd:match("'chmod' '%+x'") then return 1 end
                return 0
            end)

            local instance = helper.create_instance()
            instance:doPerformUpdate("https://example.com/update.zip", "update.zip", "v2.0.0")

            assert.is_truthy(helper.find_notification("successfully"))
        end)

        it("handles file not in update package", function()
            http_responses.code = "200"
            package.loaded["util"].pathExists = function(path)
                if path == "/tmp/koreader/plugins/localsend.koplugin" then return true end
                if path == "/tmp/koreader/plugins/localsend.koplugin/localsend" then return true end
                if path == "/tmp/localsend_update.zip" then return true end
                if path == "/tmp/localsend_update_extract/localsend.koplugin" then return true end
                if path == "/tmp/localsend_update_extract/localsend.koplugin/main.lua" then return true end
                if path == "/tmp/localsend_update_extract/localsend.koplugin/localsend" then return true end
                return false
            end

            local instance = helper.create_instance()
            instance:doPerformUpdate("https://example.com/update.zip", "update.zip", "v2.0.0")

            local found_warn = false
            for _, msg in ipairs(logger.calls.warn) do
                if msg:match("File not in update package") and msg:match("_meta%.lua") then
                    found_warn = true; break
                end
            end
            assert.is_true(found_warn)
        end)
    end)

    -- =======================================================================
    -- Version comparison integration
    -- =======================================================================
    describe("version comparison integration", function()
        it("correctly identifies older version needing update", function()
            _G.dofile = function(path)
                if path:match("_meta%.lua$") then return { version = "v1.0.0" } end
            end

            file_contents["/tmp/localsend_update_check.json"] = [[
                {"tag_name":"v1.1.0","body":"Bug fixes","assets":[
                    {"name":"localsend-koplugin-armv7.zip","browser_download_url":"https://example.com/armv7.zip"}
                ]}
            ]]

            local confirm_shown = false
            package.loaded["ui/widget/confirmbox"] = {
                new = function(self, o) confirm_shown = true; return o end,
            }

            local instance = helper.create_instance()
            instance:checkForUpdates()

            assert.is_true(confirm_shown, "Should offer update from 1.0.0 to 1.1.0")
        end)
    end)

    -- =======================================================================
    -- Auto-update settings and scheduling (merged from auto_update_check_spec.lua)
    -- =======================================================================
    describe("auto-update settings", function()
        it("should load auto_update_check setting (default true via nilOrTrue)", function()
            local instance = helper.create_instance()
            assert.is_true(instance.auto_update_check,
                "auto_update_check should default to true")
        end)

        it("should respect auto_update_check when explicitly disabled", function()
            helper.state.settings["LocalSend_auto_update_check"] = false
            local instance = helper.create_instance()
            assert.is_false(instance.auto_update_check,
                "auto_update_check should be false when explicitly disabled")
        end)

        it("should load update_check_interval_hours setting (default 168 weekly)", function()
            local instance = helper.create_instance()
            assert.equal(168, instance.update_check_interval_hours,
                "update_check_interval_hours should default to 168 (weekly)")
        end)

        it("should create check_update_task function in init()", function()
            local instance = helper.create_instance()
            assert.is_function(instance.check_update_task,
                "check_update_task should be created in init()")
        end)
    end)

    describe("auto-update scheduling", function()
        it("should have _scheduleUpdateCheck method", function()
            local instance = helper.create_instance()
            assert.is_function(instance._scheduleUpdateCheck,
                "_scheduleUpdateCheck helper should exist")
        end)

        it("should have _unscheduleUpdateCheck method", function()
            local instance = helper.create_instance()
            assert.is_function(instance._unscheduleUpdateCheck,
                "_unscheduleUpdateCheck helper should exist")
        end)
    end)

    describe("auto-update onCloseWidget cleanup", function()
        it("should unschedule check_update_task on widget close", function()
            local instance = helper.create_instance()
            local task_ref = instance.check_update_task

            helper.state.unscheduled_tasks = {}
            instance:onCloseWidget()

            local found_unschedule = false
            for _, task in ipairs(helper.state.unscheduled_tasks) do
                if task == task_ref then
                    found_unschedule = true
                    break
                end
            end

            assert.is_true(found_unschedule,
                "Should unschedule check_update_task on widget close")
        end)

        it("should nil out check_update_task reference", function()
            local instance = helper.create_instance()
            assert.is_function(instance.check_update_task)

            instance:onCloseWidget()

            assert.is_nil(instance.check_update_task,
                "check_update_task should be nil after onCloseWidget")
        end)
    end)
end)
