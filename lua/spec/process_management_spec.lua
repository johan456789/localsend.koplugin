require 'busted.runner'()
local helper = require("spec.test_helper")

-- Tests for process management: isRunning, stopServer

describe("Process Management", function()
    local pid_file_content
    local pid_file_exists
    local proc_exists_map
    local kill_calls
    local terminate_calls

    setup(function()
        helper.setup_complete()
    end)

    before_each(function()
        helper.before_each()
        pid_file_content = nil
        pid_file_exists = false
        proc_exists_map = {}
        kill_calls = {}
        terminate_calls = {}

        -- Override ffiutil for subprocess checks
        package.loaded["ffi/util"].isSubProcessDone = function(pid, wait)
            return proc_exists_map[pid] ~= true
        end
        package.loaded["ffi/util"].terminateSubProcess = function(pid)
            table.insert(terminate_calls, pid)
            proc_exists_map[pid] = false
        end

        -- Override pathExists for PID file and /proc checks
        local base_pathExists = package.loaded["util"].pathExists
        package.loaded["util"].pathExists = function(path)
            if path == "/tmp/localsend_koreader.pid" then return pid_file_exists end
            local pid = path:match("^/proc/(%d+)$")
            if pid then
                return proc_exists_map[tonumber(pid)] or false
            end
            return base_pathExists(path)
        end

        package.loaded["util"].readFromFile = function(path)
            if path == "/tmp/localsend_koreader.pid" then
                if not pid_file_exists then return nil end
                return pid_file_content
            end
            return nil
        end

        -- Mock os.execute for kill commands
        _G.os.execute = function(cmd)
            table.insert(kill_calls, cmd)
            local sig, pid = cmd:match("'kill' '%-(%w+)' '(%d+)'")
            if not sig then
                -- Also match "kill -9 12345" format
                sig, pid = cmd:match("kill %-(%d+)%s+(%d+)")
            end
            if sig and pid then
                pid = tonumber(pid)
                if sig == "KILL" or sig == "9" then
                    proc_exists_map[pid] = false
                end
            end
            return 0
        end

        -- Mock os.remove
        _G.os.remove = function(path)
            table.insert(helper.state.removed_files, path)
            if path == "/tmp/localsend_koreader.pid" then
                pid_file_exists = false
            end
            return true
        end
    end)

    describe("isRunning", function()
        it("returns false when PID file does not exist", function()
            pid_file_exists = false

            local instance = helper.create_instance()

            assert.is_false(instance:isRunning())
        end)

        it("returns false when PID file exists but is empty", function()
            pid_file_exists = true
            pid_file_content = nil

            local instance = helper.create_instance()

            assert.is_false(instance:isRunning())
        end)

        it("returns false when PID file contains non-numeric content", function()
            pid_file_exists = true
            pid_file_content = "not-a-pid"

            local instance = helper.create_instance()

            assert.is_false(instance:isRunning())
        end)

        it("returns false when PID exists but process is not running", function()
            pid_file_exists = true
            pid_file_content = "12345"
            proc_exists_map[12345] = false

            local instance = helper.create_instance()

            assert.is_false(instance:isRunning())
        end)

        it("returns true when PID exists and process is running", function()
            pid_file_exists = true
            pid_file_content = "12345"
            proc_exists_map[12345] = true

            local instance = helper.create_instance()

            assert.is_true(instance:isRunning())
        end)

        it("handles PID with newline from read(*l)", function()
            pid_file_exists = true
            pid_file_content = "12345"
            proc_exists_map[12345] = true

            local instance = helper.create_instance()

            assert.is_true(instance:isRunning())
        end)
    end)

    describe("stopServer", function()
        it("returns true when PID file does not exist", function()
            pid_file_exists = false

            local instance = helper.create_instance()
            instance.closeFirewall = function() end

            local ok = instance:stopServer()
            assert.is_true(ok)
        end)

        it("sends SIGKILL directly for guaranteed termination", function()
            pid_file_exists = true
            pid_file_content = "12345"
            proc_exists_map[12345] = true

            local kill_9_called = false
            _G.os.execute = function(cmd)
                table.insert(kill_calls, cmd)
                -- Match shell_escape format: 'kill' '-9' or unescaped: kill -9
                if cmd:match("'kill'") and cmd:match("'%-9'") then
                    kill_9_called = true
                    proc_exists_map[12345] = false
                end
                return 0
            end

            local instance = helper.create_instance()
            instance.closeFirewall = function() end

            local ok = instance:stopServer()

            assert.is_true(ok)
            assert.is_true(kill_9_called, "Should use SIGKILL (kill -9) for guaranteed termination")
        end)

        it("removes PID file BEFORE killing process", function()
            pid_file_exists = true
            pid_file_content = "12345"
            proc_exists_map[12345] = true

            local pid_removed_before_kill = false
            local kill_called = false

            _G.os.execute = function(cmd)
                table.insert(kill_calls, cmd)
                -- Match shell_escape format: 'kill' '-9' or unescaped: kill -9
                if cmd:match("'kill'") and cmd:match("'%-9'") then
                    pid_removed_before_kill = not pid_file_exists
                    kill_called = true
                end
                return 0
            end

            local instance = helper.create_instance()
            instance.closeFirewall = function() end

            instance:stopServer()

            assert.is_true(kill_called, "Should call kill")
            assert.is_true(pid_removed_before_kill, "PID file should be removed BEFORE killing")
        end)

        it("calls closeFirewall after stopping", function()
            pid_file_exists = true
            pid_file_content = "12345"
            proc_exists_map[12345] = true

            _G.os.execute = function(cmd)
                table.insert(kill_calls, cmd)
                return 0
            end

            local instance = helper.create_instance()

            local firewall_closed = false
            instance.closeFirewall = function() firewall_closed = true end

            instance:stopServer()

            assert.is_true(firewall_closed, "Firewall should be closed")
        end)

        it("always returns true (SIGKILL cannot fail)", function()
            pid_file_exists = true
            pid_file_content = "12345"
            proc_exists_map[12345] = true

            _G.os.execute = function(cmd)
                table.insert(kill_calls, cmd)
                return 0
            end

            local instance = helper.create_instance()
            instance.closeFirewall = function() end

            local ok = instance:stopServer()

            assert.is_true(ok, "stopServer always succeeds (no blocking wait)")
        end)
    end)

    describe("restart", function()
        it("stops then starts server", function()
            pid_file_exists = true
            pid_file_content = "12345"
            proc_exists_map[12345] = true

            _G.os.execute = function(cmd)
                table.insert(kill_calls, cmd)
                if cmd:match("kill %-9") then
                    proc_exists_map[12345] = false
                end
                return 0
            end

            local instance = helper.create_instance()
            instance.closeFirewall = function() end

            local stop_called = false
            local start_called = false
            local original_stopServer = instance.stopServer
            instance.stopServer = function(self)
                stop_called = true
                return original_stopServer(self)
            end
            instance.start = function()
                start_called = true
            end

            instance:restart()

            assert.is_true(stop_called, "stopServer should be called")
            assert.is_true(start_called, "start should be called")
        end)

        it("starts server even if not currently running", function()
            pid_file_exists = false

            local instance = helper.create_instance()

            local start_called = false
            instance.start = function()
                start_called = true
            end

            instance:restart()

            assert.is_true(start_called, "start should be called even when not running")
        end)
    end)
end)
