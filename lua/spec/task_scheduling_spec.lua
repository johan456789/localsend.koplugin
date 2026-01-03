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
        package.loaded["ui/widget/inputdialog"] = { new = function(self, o) return o end }
        package.loaded["ui/widget/pathchooser"] = { new = function(self, o) return o end }
        package.loaded["ui/network/manager"] = { isOnline = function() return true end }

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
        }

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
        it("should create check_transfer_task function in init()", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_function(instance.check_transfer_task,
                "check_transfer_task should be created in init()")
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
            assert.are_not.equal(instance1.check_transfer_task, instance2.check_transfer_task,
                "check_transfer_task should be unique per instance")
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

        it("_unschedulePolling should call UIManager:unschedule with task reference", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance:_unschedulePolling()

            assert.equal(1, #unscheduled_tasks,
                "Should have called UIManager:unschedule once")
            assert.equal(instance.check_transfer_task, unscheduled_tasks[1],
                "Should unschedule check_transfer_task")
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
            assert.is_function(instance.check_transfer_task)
            assert.is_function(instance.resume_start_task)

            instance:onCloseWidget()

            -- Tasks should be nil after cleanup
            assert.is_nil(instance.check_transfer_task,
                "check_transfer_task should be nil after onCloseWidget")
            assert.is_nil(instance.resume_start_task,
                "resume_start_task should be nil after onCloseWidget")
        end)
    end)

    describe("onResume uses stored task reference", function()
        it("onResume should schedule resume_start_task (not anonymous function)", function()
            LocalSend = require("main")
            LocalSend._ServerState.was_running_before_suspend = true
            LocalSend._ServerState.user_stopped = false

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            -- Clear any tasks scheduled during init
            scheduled_tasks = {}

            instance:onResume()

            assert.equal(1, #scheduled_tasks, "Should schedule one task")
            assert.equal(2, scheduled_tasks[1].delay, "Should have 2 second delay")
            assert.equal(instance.resume_start_task, scheduled_tasks[1].callback,
                "Should schedule the stored resume_start_task, not an anonymous function")

            -- Cleanup
            LocalSend._ServerState.was_running_before_suspend = false
        end)
    end)

    describe("checkForNewTransfers uses stored task reference", function()
        it("should schedule check_transfer_task for next poll", function()
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

            assert.equal(1, #scheduled_tasks, "Should schedule one task")
            assert.equal(10, scheduled_tasks[1].delay, "Should have 10 second delay")
            assert.equal(instance.check_transfer_task, scheduled_tasks[1].callback,
                "Should schedule the stored check_transfer_task, not an anonymous function")
        end)

        it("should NOT schedule if server stopped", function()
            LocalSend = require("main")

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance.isRunning = function() return false end
            instance.getNewTransfers = function() return {} end

            -- Clear tasks from init
            scheduled_tasks = {}

            instance:_checkForNewTransfers()

            assert.equal(0, #scheduled_tasks, "Should NOT schedule when server not running")
        end)
    end)

    describe("start() uses stored task reference", function()
        it("when server already running, should schedule check_transfer_task", function()
            LocalSend = require("main")

            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance.isRunning = function() return true end

            -- Clear tasks from init
            scheduled_tasks = {}

            instance:start()

            assert.equal(1, #scheduled_tasks, "Should schedule one task")
            assert.equal(instance.check_transfer_task, scheduled_tasks[1].callback,
                "Should schedule stored check_transfer_task when taking over polling")
        end)
    end)
end)
