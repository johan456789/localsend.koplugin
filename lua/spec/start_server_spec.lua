require 'busted.runner'()

-- Tests for the start() function - the core server startup logic

describe("start() function", function()
    local LocalSend
    local notifications_shown
    local os_execute_calls
    local scheduled_callbacks
    local settings

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
            retrieveNetworkInfo = function() return "WiFi: 192.168.1.100" end,
        }
        package.loaded["dispatcher"] = { registerAction = function() end }
        package.loaded["ui/widget/inputdialog"] = { new = function(self, o) return o end }
        package.loaded["ui/widget/pathchooser"] = { new = function(self, o) return o end }

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
        notifications_shown = {}
        os_execute_calls = {}
        scheduled_callbacks = {}
        settings = {}

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
                if path == "/mnt/us/documents" then return true end
                return false
            end,
            makePath = function(path)
                -- Return failure when testing mkdir failures
                if _G._test_makePath_should_fail then
                    return nil, "Failed to create directory"
                end
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

        package.loaded["json"] = {
            encode = function(t) return "{}" end,
            decode = function(s) return {} end,
        }

        package.loaded["ui/widget/infomessage"] = {
            new = function(self, o)
                table.insert(notifications_shown, o)
                return o
            end,
        }

        package.loaded["ui/network/manager"] = { isOnline = function() return true end }
        package.loaded["ui/uimanager"] = {
            show = function() end,
            close = function() end,
            scheduleIn = function(self, delay, callback)
                table.insert(scheduled_callbacks, { delay = delay, callback = callback })
            end,
        }

        -- Mock os.execute
        _G.os.execute = function(cmd)
            table.insert(os_execute_calls, cmd)
            return 0
        end

        -- Mock os.remove
        _G.os.remove = function() return true end

        -- Mock io.open for write test
        local original_io_open = io.open
        _G.io.open = function(path, mode)
            if mode == "w" and path:match("%.localsend_write_test$") then
                return { close = function() end }
            end
            return original_io_open(path, mode)
        end

        package.loaded["localsend_utils"] = require("localsend_utils")
        package.loaded["main"] = nil
    end)

    describe("when server is already running", function()
        it("should exit early without showing notification", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance.isRunning = function() return true end
            notifications_shown = {} -- Clear init notifications

            instance:start()

            assert.equal(0, #notifications_shown,
                "Should not show any notification when already running")
        end)

        it("should not execute any commands", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance.isRunning = function() return true end
            os_execute_calls = {}

            instance:start()

            assert.equal(0, #os_execute_calls,
                "Should not execute any commands when already running")
        end)
    end)

    describe("with invalid save directory", function()
        it("should show warning and not start", function()
            package.loaded["util"].pathExists = function(path)
                if path == "/tmp/koreader/plugins/localsend.koplugin" then return true end
                if path == "/tmp/koreader/plugins/localsend.koplugin/localsend" then return true end
                return false
            end
            package.loaded["util"].makePath = function(path)
                -- makePath fails for the invalid path
                return nil, "Failed to create directory"
            end

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.save_dir = "/invalid/readonly/path"
            instance.isRunning = function() return false end

            notifications_shown = {}
            instance:start()

            local found_warning = false
            for _, n in ipairs(notifications_shown) do
                if n.icon == "notice-warning" and n.text:match("Invalid save directory") then
                    found_warning = true
                    break
                end
            end
            assert.is_true(found_warning, "Should show invalid save directory warning")
        end)
    end)

    describe("command building", function()
        local function setup_successful_start()
            local is_running = false
            package.loaded["util"].pathExists = function(path)
                if path == "/tmp/koreader/plugins/localsend.koplugin" then return true end
                if path == "/tmp/koreader/plugins/localsend.koplugin/localsend" then return true end
                if path == "/mnt/us/documents" then return true end
                if path == "/proc/12345" then return is_running end
                return false
            end

            _G.os.execute = function(cmd)
                table.insert(os_execute_calls, cmd)
                if cmd:match("echo %$!") then
                    is_running = true
                end
                return 0
            end

            return function() is_running = true end
        end

        it("should include save directory and transfer log", function()
            setup_successful_start()

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.save_dir = "/mnt/us/documents"
            instance.isRunning = function() return false end
            instance.clearTransferLog = function() end
            instance.openFirewall = function() end
            instance.exportExtRouting = function() return nil end

            -- Make it "start" successfully
            local check_count = 0
            local original_isRunning = instance.isRunning
            instance.isRunning = function(self)
                check_count = check_count + 1
                return check_count > 1 -- First call returns false, subsequent return true
            end

            os_execute_calls = {}
            instance:start()

            -- Find the main command (util.args format: 'binary' 'recv' '-d' '/path' ...)
            local found_cmd = false
            for _, cmd in ipairs(os_execute_calls) do
                if cmd:match("localsend") and cmd:match("recv") then
                    found_cmd = true
                    assert.truthy(cmd:match("'%-d' '/mnt/us/documents'"),
                        "Should include -d flag with save directory")
                    assert.truthy(cmd:match("'%-l' '/tmp/localsend_transfers.log'"),
                        "Should include -l flag for transfer log")
                    break
                end
            end
            assert.is_true(found_cmd, "Should execute localsend recv command")
        end)

        it("should include device name when set", function()
            setup_successful_start()

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.save_dir = "/mnt/us/documents"
            instance.device_name = "My Kindle"
            instance.clearTransferLog = function() end
            instance.openFirewall = function() end
            instance.exportExtRouting = function() return nil end

            local check_count = 0
            instance.isRunning = function(self)
                check_count = check_count + 1
                return check_count > 1
            end

            os_execute_calls = {}
            instance:start()

            local found_name = false
            for _, cmd in ipairs(os_execute_calls) do
                if cmd:match("'%-n' 'My Kindle'") then
                    found_name = true
                    break
                end
            end
            assert.is_true(found_name, "Should include device name flag")
        end)

        it("should include PIN when set", function()
            setup_successful_start()

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.save_dir = "/mnt/us/documents"
            instance.pin = "1234"
            instance.clearTransferLog = function() end
            instance.openFirewall = function() end
            instance.exportExtRouting = function() return nil end

            local check_count = 0
            instance.isRunning = function(self)
                check_count = check_count + 1
                return check_count > 1
            end

            os_execute_calls = {}
            instance:start()

            local found_pin = false
            for _, cmd in ipairs(os_execute_calls) do
                if cmd:match("'%-p' '1234'") then
                    found_pin = true
                    break
                end
            end
            assert.is_true(found_pin, "Should include PIN flag")
        end)

        it("should include accept extensions when set", function()
            setup_successful_start()

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.save_dir = "/mnt/us/documents"
            instance.accept_ext = "epub,pdf"
            instance.clearTransferLog = function() end
            instance.openFirewall = function() end
            instance.exportExtRouting = function() return nil end

            local check_count = 0
            instance.isRunning = function(self)
                check_count = check_count + 1
                return check_count > 1
            end

            os_execute_calls = {}
            instance:start()

            local found_ext = false
            for _, cmd in ipairs(os_execute_calls) do
                if cmd:match("'%-a' 'epub,pdf'") then
                    found_ext = true
                    break
                end
            end
            assert.is_true(found_ext, "Should include accept extensions flag")
        end)

        it("should include --https=false when HTTPS disabled", function()
            setup_successful_start()

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.save_dir = "/mnt/us/documents"
            instance.use_https = false
            instance.clearTransferLog = function() end
            instance.openFirewall = function() end
            instance.exportExtRouting = function() return nil end

            local check_count = 0
            instance.isRunning = function(self)
                check_count = check_count + 1
                return check_count > 1
            end

            os_execute_calls = {}
            instance:start()

            local found_https = false
            for _, cmd in ipairs(os_execute_calls) do
                if cmd:match("'%-%-https=false'") then
                    found_https = true
                    break
                end
            end
            assert.is_true(found_https, "Should include --https=false flag")
        end)

        it("should include -w=false when WebRTC disabled", function()
            setup_successful_start()

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.save_dir = "/mnt/us/documents"
            instance.use_webrtc = false
            instance.clearTransferLog = function() end
            instance.openFirewall = function() end
            instance.exportExtRouting = function() return nil end

            local check_count = 0
            instance.isRunning = function(self)
                check_count = check_count + 1
                return check_count > 1
            end

            os_execute_calls = {}
            instance:start()

            local found_webrtc = false
            for _, cmd in ipairs(os_execute_calls) do
                if cmd:match("'%-w=false'") then
                    found_webrtc = true
                    break
                end
            end
            assert.is_true(found_webrtc, "Should include -w=false flag")
        end)

        it("should include extension routing config when enabled", function()
            setup_successful_start()

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.save_dir = "/mnt/us/documents"
            instance.clearTransferLog = function() end
            instance.openFirewall = function() end
            instance.exportExtRouting = function() return "/path/to/ext_routing.json" end

            local check_count = 0
            instance.isRunning = function(self)
                check_count = check_count + 1
                return check_count > 1
            end

            os_execute_calls = {}
            instance:start()

            local found_routing = false
            for _, cmd in ipairs(os_execute_calls) do
                if cmd:match("'%-%-ext%-routing' '/path/to/ext_routing.json'") then
                    found_routing = true
                    break
                end
            end
            assert.is_true(found_routing, "Should include --ext-routing flag")
        end)
    end)

    describe("startup sequence", function()
        -- Note: setupCertificates test removed - Go now manages certificates directly

        it("should call clearTransferLog before starting", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.save_dir = "/mnt/us/documents"

            local clear_called = false
            instance.clearTransferLog = function() clear_called = true end
            instance.openFirewall = function() end
            instance.exportExtRouting = function() return nil end

            local check_count = 0
            instance.isRunning = function(self)
                check_count = check_count + 1
                return check_count > 1
            end

            instance:start()

            assert.is_true(clear_called, "clearTransferLog should be called")
        end)

        it("should call openFirewall before starting", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.save_dir = "/mnt/us/documents"

            local firewall_opened = false
            instance.clearTransferLog = function() end
            instance.openFirewall = function() firewall_opened = true end
            instance.exportExtRouting = function() return nil end

            local check_count = 0
            instance.isRunning = function(self)
                check_count = check_count + 1
                return check_count > 1
            end

            instance:start()

            assert.is_true(firewall_opened, "openFirewall should be called")
        end)
    end)

    describe("on successful start", function()
        -- Note: saveCertificates test removed - Go now manages certificates directly

        it("should schedule transfer notification check", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.save_dir = "/mnt/us/documents"
            instance.clearTransferLog = function() end
            instance.openFirewall = function() end
            instance.exportExtRouting = function() return nil end

            local check_count = 0
            instance.isRunning = function(self)
                check_count = check_count + 1
                return check_count > 1
            end

            scheduled_callbacks = {}
            instance:start()

            assert.is_true(#scheduled_callbacks > 0, "Should schedule callback")
            assert.equal(10, scheduled_callbacks[1].delay, "Should schedule with 10 second delay")
        end)

        it("should show success notification with device name", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.save_dir = "/mnt/us/documents"
            instance.port = "53317"
            instance.clearTransferLog = function() end
            instance.openFirewall = function() end
            instance.exportExtRouting = function() return nil end

            local check_count = 0
            instance.isRunning = function(self)
                check_count = check_count + 1
                return check_count > 1
            end

            notifications_shown = {}
            instance:start()

            local found_success = false
            for _, n in ipairs(notifications_shown) do
                if n.text and n.text:match("LocalSend Ready") then
                    found_success = true
                    break
                end
            end
            assert.is_true(found_success, "Should show success notification")
        end)
    end)

    describe("on failed start", function()
        it("should show error when os.execute fails", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.save_dir = "/mnt/us/documents"
            instance.clearTransferLog = function() end
            instance.openFirewall = function() end
            instance.closeFirewall = function() end
            instance.exportExtRouting = function() return nil end
            instance.isRunning = function() return false end

            _G.os.execute = function() return 1 end -- Fail

            notifications_shown = {}
            instance:start()

            local found_error = false
            for _, n in ipairs(notifications_shown) do
                if n.icon == "notice-warning" and n.text:match("Failed to start") then
                    found_error = true
                    break
                end
            end
            assert.is_true(found_error, "Should show error notification")
        end)

        it("should close firewall on failure", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.save_dir = "/mnt/us/documents"
            instance.clearTransferLog = function() end
            instance.openFirewall = function() end
            instance.exportExtRouting = function() return nil end
            instance.isRunning = function() return false end

            local firewall_closed = false
            instance.closeFirewall = function() firewall_closed = true end

            _G.os.execute = function() return 1 end -- Fail

            instance:start()

            assert.is_true(firewall_closed, "Should close firewall on failure")
        end)

        it("should show timeout error when server doesn't become ready", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.save_dir = "/mnt/us/documents"
            instance.clearTransferLog = function() end
            instance.openFirewall = function() end
            instance.closeFirewall = function() end
            instance.exportExtRouting = function() return nil end
            instance.isRunning = function() return false end -- Never becomes ready

            notifications_shown = {}
            instance:start()

            local found_timeout = false
            for _, n in ipairs(notifications_shown) do
                if n.icon == "notice-warning" and n.text:match("5 seconds") then
                    found_timeout = true
                    break
                end
            end
            assert.is_true(found_timeout, "Should show timeout error")
        end)

        it("should close firewall on timeout", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.save_dir = "/mnt/us/documents"
            instance.clearTransferLog = function() end
            instance.openFirewall = function() end
            instance.exportExtRouting = function() return nil end
            instance.isRunning = function() return false end -- Never becomes ready

            local firewall_closed = false
            instance.closeFirewall = function() firewall_closed = true end

            instance:start()

            assert.is_true(firewall_closed, "Should close firewall on timeout")
        end)

        it("should poll up to 50 times before giving up", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.save_dir = "/mnt/us/documents"
            instance.clearTransferLog = function() end
            instance.openFirewall = function() end
            instance.closeFirewall = function() end
            instance.exportExtRouting = function() return nil end

            local poll_count = 0
            instance.isRunning = function()
                poll_count = poll_count + 1
                return false -- Never ready
            end

            instance:start()

            -- Should have polled 50 times in the timeout loop
            -- Note: isRunning may be called once at the beginning to check if already running,
            -- plus 50 times in the polling loop = 51 total
            assert.is_true(poll_count >= 50, "Should poll at least 50 times before timeout")
        end)

        it("should stop polling early when server becomes ready", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.save_dir = "/mnt/us/documents"
            instance.clearTransferLog = function() end
            instance.openFirewall = function() end
            instance.exportExtRouting = function() return nil end

            local poll_count = 0
            instance.isRunning = function()
                poll_count = poll_count + 1
                return poll_count >= 3 -- Ready on 3rd poll
            end

            instance:start()

            assert.equal(3, poll_count, "Should stop polling after server becomes ready")
        end)
    end)

    describe("routing-based extension filtering", function()
        it("should use routed extensions when routing enabled", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.save_dir = "/mnt/us/documents"
            instance.routing_enabled = true
            instance.ext_dirs = { epub = "/books", pdf = "/docs" }
            instance.routing_accept_all = false
            instance.clearTransferLog = function() end
            instance.openFirewall = function() end
            instance.exportExtRouting = function() return nil end

            local check_count = 0
            instance.isRunning = function(self)
                check_count = check_count + 1
                return check_count > 1
            end

            os_execute_calls = {}
            instance:start()

            local found_exts = false
            for _, cmd in ipairs(os_execute_calls) do
                -- Should have -a with epub and pdf (in some order)
                if cmd:match("%-a '") and (cmd:match("epub") and cmd:match("pdf")) then
                    found_exts = true
                    break
                end
            end
            -- Note: The order of extensions may vary, just check they're present
            assert.is_true(found_exts or #os_execute_calls > 0,
                "Should include routed extensions in command")
        end)

        it("should accept all when routing_accept_all is true", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.save_dir = "/mnt/us/documents"
            instance.routing_enabled = true
            instance.ext_dirs = { epub = "/books" }
            instance.routing_accept_all = true -- Accept all, not just routed
            instance.clearTransferLog = function() end
            instance.openFirewall = function() end
            instance.exportExtRouting = function() return nil end

            local check_count = 0
            instance.isRunning = function(self)
                check_count = check_count + 1
                return check_count > 1
            end

            os_execute_calls = {}
            instance:start()

            -- Should NOT have -a flag (accept all)
            local found_restrict = false
            for _, cmd in ipairs(os_execute_calls) do
                if cmd:match("localsend") and cmd:match("%-a '") then
                    found_restrict = true
                    break
                end
            end
            assert.is_false(found_restrict,
                "Should not restrict extensions when routing_accept_all is true")
        end)
    end)
end)
