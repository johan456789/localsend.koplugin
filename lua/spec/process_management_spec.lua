require 'busted.runner'()

-- Tests for process management: isRunning, stopServer

describe("Process Management", function()
    local LocalSend
    local pid_file_content
    local pid_file_exists
    local proc_exists_map
    local kill_calls
    local removed_files
    local terminate_calls

    setup(function()
        -- Dynamic ffiutil mock - will be configured in before_each
        package.loaded["ffi/util"] = {
            template = function(s, ...) return s end,
            usleep = function() end,
            sleep = function() end,
            isSubProcessDone = function(pid, wait)
                -- Returns true if subprocess is done (not running)
                return proc_exists_map[pid] ~= true
            end,
            terminateSubProcess = function(pid)
                table.insert(terminate_calls, pid)
                -- Simulate SIGTERM - process stops
                proc_exists_map[pid] = false
            end,
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
        package.loaded["ui/network/manager"] = {
            isOnline = function() return true end,
            runWhenOnline = function(self, callback) callback() end,
            runWhenConnected = function(self, callback) callback() end,
        }
        package.loaded["ui/uimanager"] = {
            show = function() end,
            close = function() end,
            scheduleIn = function() end,
            unschedule = function() end,
            preventStandby = function() end,
            allowStandby = function() end,
            getElapsedTimeSinceBoot = function() return { sec = 0, usec = 0 } end,
        }
        package.loaded["pluginshare"] = {}

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
        pid_file_content = nil
        pid_file_exists = false
        proc_exists_map = {}
        kill_calls = {}
        removed_files = {}
        terminate_calls = {}

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
                if path == "/tmp/localsend_koreader.pid" then return pid_file_exists end
                -- Check /proc/PID paths
                local pid = path:match("^/proc/(%d+)$")
                if pid then
                    return proc_exists_map[tonumber(pid)] or false
                end
                return false
            end,
            makePath = function(path)
                return true
            end,
            readFromFile = function(path)
                if path == "/tmp/localsend_koreader.pid" then
                    if not pid_file_exists then return nil end
                    return pid_file_content
                end
                return nil
            end,
            splitFilePathName = function(file)
                if file == nil or file == "" then return "", "" end
                if not file:find("/") then return "", file end
                return file:match("(.*/)(.*)")
            end,
        }

        -- Mock io.open for PID file
        local original_io_open = io.open
        _G.io.open = function(path, mode)
            if path == "/tmp/localsend_koreader.pid" and mode == "r" then
                if not pid_file_exists then return nil end
                return {
                    read = function(self, fmt)
                        return pid_file_content
                    end,
                    close = function() end,
                }
            end
            return original_io_open(path, mode)
        end

        -- Mock os.execute for kill commands
        _G.os.execute = function(cmd)
            table.insert(kill_calls, cmd)
            -- Parse kill command to simulate process termination
            -- Match quoted format from util.args: 'kill' '-TERM' '12345'
            local sig, pid = cmd:match("'kill' '%-(%w+)' '(%d+)'")
            if sig and pid then
                pid = tonumber(pid)
                if sig == "KILL" then
                    proc_exists_map[pid] = false
                end
                return 0
            end
            return 0
        end

        -- Mock os.remove
        _G.os.remove = function(path)
            table.insert(removed_files, path)
            if path == "/tmp/localsend_koreader.pid" then
                pid_file_exists = false
            end
            return true
        end

        package.loaded["main"] = nil
    end)

    describe("isRunning", function()
        it("returns false when PID file does not exist", function()
            pid_file_exists = false

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_false(instance:isRunning())
        end)

        it("returns false when PID file exists but is empty", function()
            pid_file_exists = true
            pid_file_content = nil

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_false(instance:isRunning())
        end)

        it("returns false when PID file contains non-numeric content", function()
            pid_file_exists = true
            pid_file_content = "not-a-pid"

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_false(instance:isRunning())
        end)

        it("returns false when PID exists but process is not running", function()
            pid_file_exists = true
            pid_file_content = "12345"
            proc_exists_map[12345] = false

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_false(instance:isRunning())
        end)

        it("returns true when PID exists and process is running", function()
            pid_file_exists = true
            pid_file_content = "12345"
            proc_exists_map[12345] = true

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_true(instance:isRunning())
        end)

        it("handles PID with newline from read(*l)", function()
            pid_file_exists = true
            -- read("*l") in Lua strips the newline, so this simulates what io:read("*l") returns
            pid_file_content = "12345"
            proc_exists_map[12345] = true

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_true(instance:isRunning())
        end)

        -- Note: Double-check behavior was removed for simplification
        -- These tests now verify single-check behavior
        it("returns false on single check when process not visible", function()
            pid_file_exists = true
            pid_file_content = "12345"

            package.loaded["util"].pathExists = function(path)
                if path == "/tmp/koreader/plugins/localsend.koplugin" then return true end
                if path == "/tmp/koreader/plugins/localsend.koplugin/localsend" then return true end
                if path == "/tmp/localsend_koreader.pid" then return pid_file_exists end
                if path == "/proc/12345" then return false end
                return false
            end

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local result = instance:isRunning()

            assert.is_false(result, "Should return false when process not visible")
        end)

        it("returns true when process is visible", function()
            pid_file_exists = true
            pid_file_content = "12345"

            package.loaded["util"].pathExists = function(path)
                if path == "/tmp/koreader/plugins/localsend.koplugin" then return true end
                if path == "/tmp/koreader/plugins/localsend.koplugin/localsend" then return true end
                if path == "/tmp/localsend_koreader.pid" then return pid_file_exists end
                if path == "/proc/12345" then return true end
                return false
            end

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local result = instance:isRunning()

            assert.is_true(result, "Should return true when process is visible")
        end)
    end)

    describe("stopServer", function()
        it("returns true when PID file does not exist", function()
            pid_file_exists = false

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            -- Mock closeFirewall to avoid side effects
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
                if cmd:match("kill %-9") then
                    kill_9_called = true
                    proc_exists_map[12345] = false
                end
                return 0
            end

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
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
                if cmd:match("kill %-9") then
                    -- Check if PID file was already removed
                    pid_removed_before_kill = not pid_file_exists
                    kill_called = true
                end
                return 0
            end

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
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

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local firewall_closed = false
            instance.closeFirewall = function() firewall_closed = true end

            instance:stopServer()

            assert.is_true(firewall_closed, "Firewall should be closed")
        end)

        it("always returns true (SIGKILL cannot fail)", function()
            pid_file_exists = true
            pid_file_content = "12345"
            proc_exists_map[12345] = true

            -- Even if process doesn't die (extremely rare with SIGKILL),
            -- stopServer still returns true because PID file was removed
            _G.os.execute = function(cmd)
                table.insert(kill_calls, cmd)
                -- Don't set proc_exists_map[12345] = false - process "survives"
                return 0
            end

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.closeFirewall = function() end

            local ok = instance:stopServer()

            -- stopServer always returns true now - no failure mode
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

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
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

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local start_called = false
            instance.start = function()
                start_called = true
            end

            instance:restart()

            assert.is_true(start_called, "start should be called even when not running")
        end)
    end)
end)
