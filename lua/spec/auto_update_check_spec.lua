require 'busted.runner'()

-- Tests for auto update check functionality with configurable interval

describe("Auto Update Check", function()
    local LocalSend
    local settings
    local scheduled_tasks
    local unscheduled_tasks
    local info_messages_shown
    local http_responses
    local file_contents

    setup(function()
        package.loaded["ffi/util"] = {
            template = function(s, ...) return s end,
            usleep = function() end,
            isSubProcessDone = function() return true end,
            terminateSubProcess = function() end,
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
        package.loaded["ui/widget/confirmbox"] = { new = function(self, o) return o end }

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
                return { version = "v1.0.0" }
            end
        end
    end)

    before_each(function()
        settings = {}
        scheduled_tasks = {}
        unscheduled_tasks = {}
        info_messages_shown = {}
        http_responses = {}
        file_contents = {}

        _G.G_reader_settings = {
            readSetting = function(self, key) return settings[key] end,
            saveSetting = function(self, key, value) settings[key] = value end,
            isTrue = function(self, key) return settings[key] == true end,
            nilOrTrue = function(self, key) return settings[key] ~= false end,
            flipNilOrTrue = function(self, key) settings[key] = not self:nilOrTrue(key) end,
            flipNilOrFalse = function(self, key) settings[key] = not self:isTrue(key) end,
            _settings = settings,
            _reset = function()
                for k in pairs(settings) do settings[k] = nil end
            end,
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
            makePath = function(path) return true end,
            readFromFile = function(path) return file_contents[path] end,
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
                table.insert(info_messages_shown, o)
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
                table.insert(scheduled_tasks, { delay = delay, callback = callback })
            end,
            unschedule = function(self, callback)
                table.insert(unscheduled_tasks, callback)
            end,
            preventStandby = function() end,
            allowStandby = function() end,
            getElapsedTimeSinceBoot = function() return { sec = 0, usec = 0 } end,
        }

        package.loaded["pluginshare"] = {}

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

        package.loaded["localsend_utils"] = require("localsend_utils")
        package.loaded["main"] = nil
    end)

    describe("settings initialization", function()
        it("should load auto_update_check setting (default true via nilOrTrue)", function()
            -- No setting means nilOrTrue returns true
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_true(instance.auto_update_check,
                "auto_update_check should default to true")
        end)

        it("should respect auto_update_check when explicitly disabled", function()
            settings["LocalSend_auto_update_check"] = false

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_false(instance.auto_update_check,
                "auto_update_check should be false when explicitly disabled")
        end)

        it("should load update_check_interval_hours setting (default 168 weekly)", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.equal(168, instance.update_check_interval_hours,
                "update_check_interval_hours should default to 168 (weekly)")
        end)

        it("should load custom update_check_interval_hours from settings", function()
            settings["LocalSend_update_check_interval_hours"] = 24

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.equal(24, instance.update_check_interval_hours,
                "update_check_interval_hours should load from settings")
        end)

        it("should load last_update_check from settings", function()
            settings["LocalSend_last_update_check"] = 1700000000

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.equal(1700000000, instance.last_update_check,
                "last_update_check should load from settings")
        end)

        it("should create check_update_task function in init()", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_function(instance.check_update_task,
                "check_update_task should be created in init()")
        end)
    end)

    describe("scheduling", function()
        it("should schedule update check on init when enabled", function()
            LocalSend = require("main")

            scheduled_tasks = {}  -- Clear tasks from init

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            -- Find if check_update_task was scheduled
            local found_update_task = false
            for _, task in ipairs(scheduled_tasks) do
                if task.callback == instance.check_update_task then
                    found_update_task = true
                    break
                end
            end

            assert.is_true(found_update_task,
                "Should schedule update check on init when enabled")
        end)

        it("should NOT schedule update check when disabled", function()
            settings["LocalSend_auto_update_check"] = false

            LocalSend = require("main")

            scheduled_tasks = {}

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            -- Find if check_update_task was scheduled
            local found_update_task = false
            for _, task in ipairs(scheduled_tasks) do
                if task.callback == instance.check_update_task then
                    found_update_task = true
                    break
                end
            end

            assert.is_false(found_update_task,
                "Should NOT schedule update check when disabled")
        end)

        it("should have _getUpdateCheckDelay method", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_function(instance._getUpdateCheckDelay,
                "_getUpdateCheckDelay method should exist")
        end)

        it("should calculate delay based on last check time", function()
            -- Last check was 12 hours ago, interval is 24 hours
            local now = os.time()
            settings["LocalSend_last_update_check"] = now - (12 * 3600)  -- 12 hours ago
            settings["LocalSend_update_check_interval_hours"] = 24

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local delay = instance:_getUpdateCheckDelay()

            -- Should be approximately 12 hours (with some tolerance for test execution time)
            assert.is_true(delay > 10 * 3600 and delay <= 12 * 3600,
                "Delay should be remaining time (~12 hours)")
        end)

        it("should return startup delay if overdue", function()
            -- Last check was 36 hours ago, interval is 24 hours
            local now = os.time()
            settings["LocalSend_last_update_check"] = now - (36 * 3600)  -- 36 hours ago
            settings["LocalSend_update_check_interval_hours"] = 24

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local delay = instance:_getUpdateCheckDelay()

            -- Should be startup delay (60 seconds)
            assert.equal(60, delay,
                "Should return 60 second startup delay when overdue")
        end)

        it("should have _scheduleUpdateCheck method", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_function(instance._scheduleUpdateCheck,
                "_scheduleUpdateCheck method should exist")
        end)

        it("should have _unscheduleUpdateCheck method", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_function(instance._unscheduleUpdateCheck,
                "_unscheduleUpdateCheck method should exist")
        end)
    end)

    describe("auto-check execution", function()
        it("should have _autoCheckForUpdates method", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_function(instance._autoCheckForUpdates,
                "_autoCheckForUpdates method should exist")
        end)

        it("should silently skip when offline", function()
            package.loaded["ui/network/manager"] = {
                isOnline = function() return false end,
                runWhenOnline = function(self, callback) end,  -- Don't call callback
                runWhenConnected = function(self, callback) callback() end,
                isConnected = function() return true end,
            }

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            info_messages_shown = {}
            scheduled_tasks = {}

            instance:_autoCheckForUpdates()

            -- Should not show any error notification
            assert.equal(0, #info_messages_shown,
                "Should not show notification when offline")

            -- Should reschedule for later
            local found_reschedule = false
            for _, task in ipairs(scheduled_tasks) do
                if task.callback == instance.check_update_task then
                    found_reschedule = true
                    break
                end
            end

            assert.is_true(found_reschedule,
                "Should reschedule update check when offline")
        end)

        it("should notify on every check when update available", function()
            file_contents["/tmp/localsend_update_check.json"] = [[
                {"tag_name":"v2.0.0","body":"New features","assets":[
                    {"name":"localsend-koplugin-armv7.zip","browser_download_url":"https://example.com/armv7.zip"}
                ]}
            ]]
            http_responses.code = "200"

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            -- First check
            info_messages_shown = {}
            instance:_doAutoCheckForUpdates()

            local first_count = #info_messages_shown
            assert.is_true(first_count >= 1,
                "Should show notification on first check")

            -- Second check - should show again
            info_messages_shown = {}
            scheduled_tasks = {}
            instance:_doAutoCheckForUpdates()

            assert.is_true(#info_messages_shown >= 1,
                "Should show notification on every check, not just first")
        end)

        it("should update last_update_check timestamp after check", function()
            file_contents["/tmp/localsend_update_check.json"] = [[
                {"tag_name":"v1.0.0","body":"Same version"}
            ]]
            http_responses.code = "200"

            local before = os.time()

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance:_doAutoCheckForUpdates()

            local after = os.time()

            assert.is_true(instance.last_update_check >= before and instance.last_update_check <= after,
                "Should update last_update_check timestamp")
            assert.is_true(settings["LocalSend_last_update_check"] >= before,
                "Should persist last_update_check to settings")
        end)

        it("should reschedule next check after completion", function()
            file_contents["/tmp/localsend_update_check.json"] = [[
                {"tag_name":"v1.0.0","body":"Same version"}
            ]]
            http_responses.code = "200"

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            scheduled_tasks = {}

            instance:_doAutoCheckForUpdates()

            local found_reschedule = false
            for _, task in ipairs(scheduled_tasks) do
                if task.callback == instance.check_update_task then
                    found_reschedule = true
                    break
                end
            end

            assert.is_true(found_reschedule,
                "Should reschedule next check after completion")
        end)
    end)

    describe("suspend/resume handling", function()
        it("should unschedule update check on suspend", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            -- Mock server running to enable suspend handler
            instance.isRunning = function() return true end
            instance._cached_running = true

            unscheduled_tasks = {}

            instance:_onSuspend()

            -- Check that check_update_task was unscheduled
            local found_unschedule = false
            for _, task in ipairs(unscheduled_tasks) do
                if task == instance.check_update_task then
                    found_unschedule = true
                    break
                end
            end

            assert.is_true(found_unschedule,
                "Should unschedule update check on suspend")
        end)

        it("should reschedule update check on resume", function()
            LocalSend = require("main")
            LocalSend._ServerState.was_running_before_suspend = true

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance.isRunning = function() return false end
            instance.start = function() end  -- Mock start

            scheduled_tasks = {}

            instance:_onResume()

            -- Check that check_update_task was scheduled
            local found_schedule = false
            for _, task in ipairs(scheduled_tasks) do
                if task.callback == instance.check_update_task then
                    found_schedule = true
                    break
                end
            end

            assert.is_true(found_schedule,
                "Should reschedule update check on resume")

            -- Cleanup
            LocalSend._ServerState.was_running_before_suspend = false
        end)
    end)

    describe("onCloseWidget cleanup", function()
        it("should unschedule check_update_task on widget close", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            -- Store reference before it gets nil'd
            local task_ref = instance.check_update_task

            unscheduled_tasks = {}

            instance:onCloseWidget()

            -- Check that check_update_task was unscheduled
            local found_unschedule = false
            for _, task in ipairs(unscheduled_tasks) do
                if task == task_ref then
                    found_unschedule = true
                    break
                end
            end

            assert.is_true(found_unschedule,
                "Should unschedule check_update_task on widget close")
        end)

        it("should nil out check_update_task reference", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            -- Verify task exists before
            assert.is_function(instance.check_update_task)

            instance:onCloseWidget()

            assert.is_nil(instance.check_update_task,
                "check_update_task should be nil after onCloseWidget")
        end)
    end)
end)
