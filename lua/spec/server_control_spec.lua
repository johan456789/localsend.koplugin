require 'busted.runner'()
local helper = require("spec.test_helper")

-- Tests for server control: toggle, stop(), and stopServer()

describe("Server Control", function()
    setup(function()
        helper.setup_complete()
    end)

    before_each(function()
        helper.before_each()
    end)

    -- Tests for onToggleLocalSend (merged from toggle_localsend_spec.lua)
    describe("onToggleLocalSend", function()
        describe("when server is running", function()
            it("should call stop()", function()
                local instance = helper.create_instance()

                local stop_called = false
                instance.isRunning = function() return true end
                instance.stop = function() stop_called = true end

                instance:onToggleLocalSend()

                assert.is_true(stop_called, "Should call stop when running")
            end)

            it("should not call start()", function()
                local instance = helper.create_instance()

                local start_called = false
                instance.isRunning = function() return true end
                instance.stop = function() end
                instance.start = function() start_called = true end

                instance:onToggleLocalSend()

                assert.is_false(start_called, "Should not call start when running")
            end)
        end)

        describe("when server is not running", function()
            it("should call start()", function()
                local instance = helper.create_instance()

                local start_called = false
                instance.isRunning = function() return false end
                instance.start = function() start_called = true end

                instance:onToggleLocalSend()

                assert.is_true(start_called, "Should call start when not running")
            end)

            it("should clear user_stopped flag", function()
                local LocalSend = require("main")
                LocalSend._ServerState.user_stopped = true

                local instance = helper.create_instance()

                instance.isRunning = function() return false end
                instance.start = function() end

                instance:onToggleLocalSend()

                assert.is_false(LocalSend._ServerState.user_stopped,
                    "Should clear user_stopped flag when starting")
            end)
        end)

        describe("toggle behavior", function()
            it("should toggle from running to stopped", function()
                local instance = helper.create_instance()

                local actions = {}
                instance.isRunning = function() return true end
                instance.stop = function() table.insert(actions, "stop") end
                instance.start = function() table.insert(actions, "start") end

                instance:onToggleLocalSend()

                assert.same({ "stop" }, actions)
            end)

            it("should toggle from stopped to running", function()
                local instance = helper.create_instance()

                local actions = {}
                instance.isRunning = function() return false end
                instance.stop = function() table.insert(actions, "stop") end
                instance.start = function() table.insert(actions, "start") end

                instance:onToggleLocalSend()

                assert.same({ "start" }, actions)
            end)
        end)
    end)

    -- Tests for stop() wrapper (merged from stop_wrapper_spec.lua)
    describe("stop() wrapper", function()
        describe("user_stopped flag", function()
            it("should set user_stopped flag in ServerState", function()
                local instance, LocalSend = helper.create_instance()
                instance.stopServer = function() return true end

                instance:stop()

                assert.is_true(LocalSend._ServerState.user_stopped,
                    "Should set user_stopped flag")
            end)

            it("should set flag before attempting stop", function()
                local instance, LocalSend = helper.create_instance()

                local flag_was_set = false
                instance.stopServer = function()
                    flag_was_set = LocalSend._ServerState.user_stopped
                    return true
                end

                instance:stop()

                assert.is_true(flag_was_set,
                    "Flag should be set before stopServer is called")
            end)
        end)

        describe("simple stop behavior", function()
            it("should call stopServer once", function()
                local instance = helper.create_instance()

                local stop_call_count = 0
                instance.stopServer = function(self)
                    stop_call_count = stop_call_count + 1
                    return true
                end

                instance:stop()

                assert.equal(1, stop_call_count, "Should call stopServer exactly once")
            end)

            it("should always show success notification", function()
                local instance = helper.create_instance()
                instance.stopServer = function() return true end

                instance:stop()

                local notification = helper.find_notification("LocalSend stopped")
                assert.is_truthy(notification, "Should show success notification")
            end)

            it("success notification should have timeout", function()
                local instance = helper.create_instance()
                instance.stopServer = function() return true end

                instance:stop()

                local notification = helper.find_notification("LocalSend stopped")
                assert.is_not_nil(notification)
                assert.equal(2, notification.timeout, "Success notification should have 2 second timeout")
            end)
        end)
    end)

    -- Tests for stopServer behavior
    describe("stopServer", function()
        it("should return true when no PID file exists", function()
            local instance = helper.create_instance()
            local result = instance:stopServer()
            assert.is_true(result, "Should return true when no PID file")
        end)

        it("should use SIGKILL (signal 9) for guaranteed termination", function()
            local kill_signal_used = nil

            package.loaded["util"].pathExists = function(path)
                if path == "/tmp/koreader/plugins/localsend.koplugin" then return true end
                if path == "/tmp/koreader/plugins/localsend.koplugin/localsend" then return true end
                if path == "/tmp/localsend_koreader.pid" then return true end
                if path == "/proc/12345" then return true end
                return false
            end
            package.loaded["util"].readFromFile = function(path)
                if path == "/tmp/localsend_koreader.pid" then return "12345" end
                return nil
            end

            local original_execute = os.execute
            os.execute = function(cmd)
                if cmd:match("kill") then
                    if cmd:match("kill %-9") then kill_signal_used = 9 end
                end
                return 0
            end

            local instance = helper.create_instance()
            instance:stopServer()

            os.execute = original_execute

            assert.equal(9, kill_signal_used, "Should use SIGKILL (signal 9)")
        end)
    end)
end)
