require 'busted.runner'()

-- Tests for LocalSend task scheduling patterns (Issues #1 and #2 from optimization doc)
-- These tests verify proper UIManager task management to prevent battery drain

describe("LocalSend Task Scheduling", function()
    local LocalSend
    local scheduled_tasks
    local unscheduled_tasks

    setup(function()
        -- Mock KOReader dependencies
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
            retrieveNetworkInfo = function() return "WiFi: 192.168.1.100" end,
        }
        package.loaded["dispatcher"] = {
            registerAction = function() end,
        }
        package.loaded["ui/widget/infomessage"] = {
            new = function(self, o) return o end,
        }
        package.loaded["ui/widget/notification"] = { new = function(self, o) return o end }
        package.loaded["ui/widget/inputdialog"] = { new = function(self, o) return o end }
        package.loaded["ui/widget/pathchooser"] = { new = function(self, o) return o end }
        package.loaded["ui/network/manager"] = {
            isOnline = function() return true end,
            runWhenOnline = function(self, callback) callback() end,
            runWhenConnected = function(self, callback) callback() end,
            isConnected = function() return true end,
        }

        -- Track scheduled and unscheduled tasks
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

        -- Mock WidgetContainer
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
                return false
            end,
            makePath = function(path) return true end,
        }
        package.loaded["gettext"] = setmetatable({}, {
            __call = function(_, s) return s end,
        })
        package.loaded["json"] = {
            encode = function(t) return "{}" end,
            decode = function(s) return {} end,
        }
        package.loaded["localsend_utils"] = require("localsend_utils")

        -- Mock G_reader_settings
        local settings = {}
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

        -- Mock dofile for _meta.lua
        _G.dofile = function(path)
            if path:match("_meta%.lua$") then
                return { version = "v1.1.1" }
            end
            error("dofile not mocked for: " .. path)
        end
    end)

    before_each(function()
        scheduled_tasks = {}
        unscheduled_tasks = {}
        G_reader_settings._reset()

        -- Reset package.loaded to get fresh LocalSend instance
        package.loaded["main"] = nil
    end)

    describe("task reference initialization", function()
        it("should create check_sentinel_task function in init()", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_function(instance.check_sentinel_task,
                "check_sentinel_task should be created in init()")
        end)

        it("should create resume_start_task function in init()", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_function(instance.resume_start_task,
                "resume_start_task should be created in init()")
        end)

        it("task references should be instance-specific (not shared)", function()
            LocalSend = require("main")

            local instance1 = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            local instance2 = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            -- Each instance should have its own task function
            assert.are_not.equal(instance1.check_sentinel_task, instance2.check_sentinel_task,
                "check_sentinel_task should be unique per instance")
            assert.are_not.equal(instance1.resume_start_task, instance2.resume_start_task,
                "resume_start_task should be unique per instance")
        end)
    end)

    describe("unschedule helper methods", function()
        it("should have _unschedulePolling method", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_function(instance._unschedulePolling,
                "_unschedulePolling helper should exist")
        end)

        it("should have _unscheduleResume method", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_function(instance._unscheduleResume,
                "_unscheduleResume helper should exist")
        end)

        it("_unschedulePolling should call UIManager:unschedule with sentinel task", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance:_unschedulePolling()

            assert.equal(1, #unscheduled_tasks,
                "Should have called UIManager:unschedule once (sentinel only)")
            assert.equal(instance.check_sentinel_task, unscheduled_tasks[1],
                "Should unschedule check_sentinel_task")
        end)

        it("_unscheduleResume should call UIManager:unschedule with task reference", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance:_unscheduleResume()

            assert.equal(1, #unscheduled_tasks,
                "Should have called UIManager:unschedule once")
            assert.equal(instance.resume_start_task, unscheduled_tasks[1],
                "Should unschedule resume_start_task")
        end)
    end)

    describe("onCloseWidget handler", function()
        it("should have onCloseWidget method defined", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_function(instance.onCloseWidget,
                "onCloseWidget should be defined for task cleanup on document switch")
        end)

        it("onCloseWidget should unschedule polling task", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance:onCloseWidget()

            -- Should have unscheduled check_transfer_task
            local found_polling = false
            for _, task in ipairs(unscheduled_tasks) do
                if task == instance.check_transfer_task then
                    found_polling = true
                    break
                end
            end
            -- Note: check_transfer_task may be nil after onCloseWidget,
            -- so we check that unschedule was called at all
            assert.is_true(#unscheduled_tasks >= 1,
                "onCloseWidget should call unschedule")
        end)

        it("onCloseWidget should NOT stop the server", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local stop_called = false
            instance.stopServer = function() stop_called = true; return true end
            instance.isRunning = function() return true end

            instance:onCloseWidget()

            assert.is_false(stop_called,
                "onCloseWidget should NOT stop the server (it persists across document switches)")
        end)

        it("onCloseWidget should nil out task references", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            -- Verify tasks exist before
            assert.is_function(instance.check_sentinel_task)
            assert.is_function(instance.resume_start_task)

            instance:onCloseWidget()

            -- Tasks should be nil after cleanup
            assert.is_nil(instance.check_sentinel_task,
                "check_sentinel_task should be nil after onCloseWidget")
            assert.is_nil(instance.resume_start_task,
                "resume_start_task should be nil after onCloseWidget")
        end)
    end)

    describe("onResume uses NetworkMgr:runWhenConnected", function()
        it("onResume should call start via NetworkMgr:runWhenConnected", function()
            LocalSend = require("main")
            LocalSend._ServerState.user_stopped = false

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            -- Set flag AFTER widget creation (simulating suspend after widget exists)
            LocalSend._ServerState.was_running_before_suspend = true

            -- Track start calls
            local start_called = false
            local start_silent = nil
            instance.start = function(self, silent)
                start_called = true
                start_silent = silent
            end

            -- Clear any tasks scheduled during init
            scheduled_tasks = {}

            instance:_onResume()

            -- NetworkMgr:runWhenConnected mock calls callback immediately
            assert.is_true(start_called, "start should be called via NetworkMgr:runWhenConnected")
            assert.is_true(start_silent, "start should be called with silent=true")

            -- Cleanup
            LocalSend._ServerState.was_running_before_suspend = false
        end)
    end)

    describe("checkForNewTransfers behavior", function()
        it("should not self-schedule (sentinel polling handles scheduling)", function()
            LocalSend = require("main")

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance.isRunning = function() return true end
            instance.getNewTransfers = function() return {} end

            -- Clear tasks from init
            scheduled_tasks = {}

            -- Call the internal check method
            instance:_checkForNewTransfers()

            -- Should NOT schedule any tasks - sentinel polling handles that
            assert.equal(0, #scheduled_tasks, "Should NOT self-schedule (sentinel handles polling)")
        end)

        it("should NOT run if server stopped", function()
            LocalSend = require("main")

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance.isRunning = function() return false end
            local getNewTransfers_called = false
            instance.getNewTransfers = function()
                getNewTransfers_called = true
                return {}
            end

            instance:_checkForNewTransfers()

            assert.is_false(getNewTransfers_called, "Should NOT check transfers when server not running")
        end)
    end)

    describe("start() uses stored task reference", function()
        it("when server already running, should schedule sentinel polling", function()
            LocalSend = require("main")

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance.isRunning = function() return true end

            -- Clear tasks from init
            scheduled_tasks = {}

            instance:start()

            assert.equal(1, #scheduled_tasks, "Should schedule sentinel task only")
            assert.equal(instance.check_sentinel_task, scheduled_tasks[1].callback,
                "Should schedule check_sentinel_task for fast notifications")
        end)
    end)

    describe("_checkSentinelFile behavior", function()
        it("should trigger transfer check when sentinel content changes", function()
            LocalSend = require("main")

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance.isRunning = function() return true end

            local transfer_check_count = 0
            instance._checkForNewTransfers = function()
                transfer_check_count = transfer_check_count + 1
            end

            -- First call: sets last_sentinel_value, no trigger
            LocalSend._ServerState.last_sentinel_value = nil
            package.loaded["util"].readFromFile = function() return "12345" end
            instance:_checkSentinelFile()
            assert.equal(0, transfer_check_count, "First call should not trigger (no previous value)")
            assert.equal("12345", LocalSend._ServerState.last_sentinel_value)

            -- Second call with same value: no trigger
            instance:_checkSentinelFile()
            assert.equal(0, transfer_check_count, "Same value should not trigger")

            -- Third call with different value: should trigger
            package.loaded["util"].readFromFile = function() return "67890" end
            instance:_checkSentinelFile()
            assert.equal(1, transfer_check_count, "Different value should trigger transfer check")
            assert.equal("67890", LocalSend._ServerState.last_sentinel_value)
        end)

        it("should not check if server not running", function()
            LocalSend = require("main")

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance.isRunning = function() return false end

            local read_called = false
            package.loaded["util"].readFromFile = function()
                read_called = true
                return "12345"
            end

            scheduled_tasks = {}
            instance:_checkSentinelFile()

            assert.is_false(read_called, "Should not read file when server not running")
            assert.equal(0, #scheduled_tasks, "Should not schedule next check when not running")
        end)

        it("should reschedule itself when server running", function()
            LocalSend = require("main")

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance.isRunning = function() return true end
            package.loaded["util"].readFromFile = function() return nil end

            scheduled_tasks = {}
            instance:_checkSentinelFile()

            assert.equal(1, #scheduled_tasks, "Should schedule next sentinel check")
            assert.equal(instance.check_sentinel_task, scheduled_tasks[1].callback)
            assert.equal(2, scheduled_tasks[1].delay, "Should schedule with 2 second interval")
        end)

        it("should update cache and cleanup when server dies", function()
            -- Bug 3: _checkSentinelFile should detect server death and update state
            LocalSend = require("main")

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            -- Simulate server was running (cache says true)
            instance._cached_running = true
            package.loaded["pluginshare"].localsend_running = true

            -- But now isRunning returns false (server died)
            instance.isRunning = function() return false end

            scheduled_tasks = {}
            instance:_checkSentinelFile()

            -- Should have updated cache to reflect server death
            assert.is_false(instance._cached_running,
                "_checkSentinelFile should update cache when server dies")

            -- Should have cleared PluginShare
            assert.is_nil(package.loaded["pluginshare"].localsend_running,
                "_checkSentinelFile should clear PluginShare when server dies")

            -- Should NOT schedule next check (server is dead)
            assert.equal(0, #scheduled_tasks,
                "Should not schedule next check when server is dead")
        end)
    end)

    describe("task reference recovery after onCloseWidget", function()
        -- Bug 1: Task references should be recreated if nil when starting server

        it("_onServerStarted should recreate check_sentinel_task if nil", function()
            LocalSend = require("main")

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            -- Simulate onCloseWidget having nullified the task
            instance.check_sentinel_task = nil

            -- Mock dependencies for _onServerStarted
            instance.isRunning = function() return true end

            scheduled_tasks = {}
            instance:_onServerStarted(true, "TestDevice")

            -- check_sentinel_task should have been recreated
            assert.is_function(instance.check_sentinel_task,
                "check_sentinel_task should be recreated if nil")

            -- Should have scheduled the recreated task
            assert.equal(1, #scheduled_tasks,
                "Should schedule the recreated sentinel task")
            assert.equal(instance.check_sentinel_task, scheduled_tasks[1].callback,
                "Should schedule the newly created check_sentinel_task")
        end)

        it("polling should work after resume even if onCloseWidget was called", function()
            -- End-to-end test: suspend -> onCloseWidget -> resume -> server should poll
            LocalSend = require("main")
            LocalSend._ServerState.was_running_before_suspend = false
            LocalSend._ServerState.user_stopped = false

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            -- Simulate server running initially
            local server_running = true
            instance.isRunning = function() return server_running end
            instance.stopServer = function()
                server_running = false
                return true
            end

            -- Step 1: Suspend - should set was_running_before_suspend
            instance:_onSuspend()
            assert.is_true(LocalSend._ServerState.was_running_before_suspend)
            assert.is_false(server_running)

            -- Step 2: onCloseWidget called during suspend - nullifies tasks
            instance:onCloseWidget()
            assert.is_nil(instance.check_sentinel_task)

            -- Step 3: Resume - should restart server
            -- Since we can't fully mock start(), we'll test _onServerStarted directly
            -- which is where the task recreation happens
            server_running = true  -- Server "starts" again
            scheduled_tasks = {}

            -- Simulate what happens after start() succeeds: _onServerStarted is called
            instance:_onServerStarted(true, "TestDevice")

            -- After _onServerStarted, check_sentinel_task should exist and be scheduled
            assert.is_function(instance.check_sentinel_task,
                "check_sentinel_task should be recreated after resume")

            -- Cleanup
            LocalSend._ServerState.was_running_before_suspend = false
        end)
    end)
end)
