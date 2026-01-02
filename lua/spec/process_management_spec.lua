require 'busted.runner'()

-- Tests for process management: isRunning, stopServer

describe("Process Management", function()
    local LocalSend
    local pid_file_content
    local pid_file_exists
    local proc_exists_map
    local kill_calls
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
        package.loaded["ui/widget/infomessage"] = { new = function(self, o) return o end }
        package.loaded["ui/widget/inputdialog"] = { new = function(self, o) return o end }
        package.loaded["ui/widget/pathchooser"] = { new = function(self, o) return o end }
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
        pid_file_content = nil
        pid_file_exists = false
        proc_exists_map = {}
        kill_calls = {}
        removed_files = {}

        package.loaded["util"] = {
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
            local sig, pid = cmd:match("kill %-(%w+) (%d+)")
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

        it("returns true on second check if first fails (double-check)", function()
            pid_file_exists = true
            pid_file_content = "12345"

            -- Process becomes visible on second check (simulating race condition)
            local check_count = 0
            package.loaded["util"].pathExists = function(path)
                if path == "/tmp/koreader/plugins/localsend.koplugin" then return true end
                if path == "/tmp/koreader/plugins/localsend.koplugin/localsend" then return true end
                if path == "/tmp/localsend_koreader.pid" then return pid_file_exists end
                if path == "/proc/12345" then
                    check_count = check_count + 1
                    return check_count >= 2 -- Fail first check, succeed on second
                end
                return false
            end

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local result = instance:isRunning()

            assert.is_true(result, "Should return true after double-check succeeds")
            assert.is_true(check_count >= 2, "Should have checked at least twice")
        end)

        it("returns false if both checks fail", function()
            pid_file_exists = true
            pid_file_content = "12345"

            -- Process never visible
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

            assert.is_false(result, "Should return false if both checks fail")
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

            local ok = instance:stopServer(false)
            assert.is_true(ok)
        end)

        it("sends SIGTERM first", function()
            pid_file_exists = true
            pid_file_content = "12345"
            proc_exists_map[12345] = true

            -- Process exits after TERM
            local term_count = 0
            _G.os.execute = function(cmd)
                table.insert(kill_calls, cmd)
                if cmd:match("kill %-TERM") then
                    term_count = term_count + 1
                    proc_exists_map[12345] = false
                end
                return 0
            end

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.closeFirewall = function() end

            local ok = instance:stopServer(false)

            assert.is_true(ok)
            assert.equal(1, term_count, "Should send SIGTERM")
        end)

        it("sends SIGKILL when force=true and process doesn't exit", function()
            pid_file_exists = true
            pid_file_content = "12345"
            proc_exists_map[12345] = true

            local kill_count = 0
            _G.os.execute = function(cmd)
                table.insert(kill_calls, cmd)
                if cmd:match("kill %-KILL") then
                    kill_count = kill_count + 1
                    proc_exists_map[12345] = false
                end
                return 0
            end

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.closeFirewall = function() end

            local ok = instance:stopServer(true)

            assert.is_true(ok)
            assert.is_true(kill_count >= 1, "Should send SIGKILL when force=true")
        end)

        it("removes PID file after successful stop", function()
            pid_file_exists = true
            pid_file_content = "12345"
            proc_exists_map[12345] = true

            _G.os.execute = function(cmd)
                if cmd:match("kill") then
                    proc_exists_map[12345] = false
                end
                return 0
            end

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.closeFirewall = function() end

            instance:stopServer(false)

            local found_pid_removal = false
            for _, path in ipairs(removed_files) do
                if path == "/tmp/localsend_koreader.pid" then
                    found_pid_removal = true
                    break
                end
            end
            assert.is_true(found_pid_removal, "PID file should be removed")
        end)

        it("calls closeFirewall after stopping", function()
            pid_file_exists = true
            pid_file_content = "12345"
            proc_exists_map[12345] = true

            _G.os.execute = function(cmd)
                if cmd:match("kill") then
                    proc_exists_map[12345] = false
                end
                return 0
            end

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local firewall_closed = false
            instance.closeFirewall = function() firewall_closed = true end

            instance:stopServer(false)

            assert.is_true(firewall_closed, "Firewall should be closed")
        end)

        it("returns error when process won't die", function()
            pid_file_exists = true
            pid_file_content = "12345"
            proc_exists_map[12345] = true

            -- Process never exits
            _G.os.execute = function(cmd)
                table.insert(kill_calls, cmd)
                return 0
            end

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.closeFirewall = function() end

            local ok, err = instance:stopServer(true)

            assert.is_false(ok)
            assert.truthy(err:match("did not exit"))
        end)
    end)

    describe("restart", function()
        it("stops then starts server", function()
            pid_file_exists = true
            pid_file_content = "12345"
            proc_exists_map[12345] = true

            _G.os.execute = function(cmd)
                if cmd:match("kill") then
                    proc_exists_map[12345] = false
                    pid_file_exists = false
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
            instance.stopServer = function(self, force)
                stop_called = true
                return original_stopServer(self, force)
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
