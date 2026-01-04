require 'busted.runner'()

-- Tests for network info display in server start notification

describe("Network Info Display", function()
    local LocalSend
    local notifications_shown
    local settings

    setup(function()
        package.loaded["ffi/util"] = {
            template = function(s, ...)
                -- Simple template implementation for testing
                local args = {...}
                local result = s
                for i, v in ipairs(args) do
                    result = result:gsub("%%" .. i, tostring(v))
                end
                return result
            end,
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

        package.loaded["ui/widget/notification"] = {
            new = function(self, o)
                table.insert(notifications_shown, o)
                return o
            end,
        }
        package.loaded["ui/network/manager"] = {
            isOnline = function() return true end,
            runWhenOnline = function(self, callback) callback() end,
            runWhenConnected = function(self, callback) callback() end,
            isConnected = function() return true end,
        }
        package.loaded["ui/uimanager"] = {
            show = function() end,
            close = function() end,
            scheduleIn = function(self, delay, callback) end,
            unschedule = function() end,
            preventStandby = function() end,
            allowStandby = function() end,
            getElapsedTimeSinceBoot = function() return { sec = 0, usec = 0 } end,
        }
        package.loaded["pluginshare"] = {}

        _G.os.execute = function() return 0 end
        _G.os.remove = function() return true end

        local original_io_open = io.open
        _G.io.open = function(path, mode)
            if mode == "w" and path:match("%.localsend_write_test$") then
                return { close = function() end }
            end
            return original_io_open(path, mode)
        end

        package.loaded["localsend_utils"] = require("localsend_utils")
        package.loaded["main"] = nil
        package.loaded["device"] = nil
    end)

    local function create_instance_and_start()
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
        return instance
    end

    describe("when retrieveNetworkInfo is available", function()
        it("shows network info in success notification", function()
            package.loaded["device"] = {
                isKindle = function() return false end,
                retrieveNetworkInfo = function() return "WiFi: 192.168.1.100" end,
            }

            create_instance_and_start()

            local found_ip = false
            for _, n in ipairs(notifications_shown) do
                if n.text and n.text:match("192%.168%.1%.100") then
                    found_ip = true
                    break
                end
            end
            assert.is_true(found_ip, "Should include IP address in notification")
        end)

        it("includes WiFi info when returned by device", function()
            package.loaded["device"] = {
                isKindle = function() return false end,
                retrieveNetworkInfo = function() return "Interface: wlan0\nIP: 10.0.0.42\nSSID: MyNetwork" end,
            }

            create_instance_and_start()

            local found_network = false
            for _, n in ipairs(notifications_shown) do
                if n.text and (n.text:match("10%.0%.0%.42") or n.text:match("wlan0")) then
                    found_network = true
                    break
                end
            end
            assert.is_true(found_network, "Should include network info in notification")
        end)
    end)

    describe("when retrieveNetworkInfo is nil (old KOReader)", function()
        it("shows success message without network info", function()
            package.loaded["device"] = {
                isKindle = function() return false end,
                retrieveNetworkInfo = nil,
            }

            create_instance_and_start()

            local found_success = false
            for _, n in ipairs(notifications_shown) do
                if n.text and n.text:match("LocalSend Ready") then
                    found_success = true
                    break
                end
            end
            assert.is_true(found_success, "Should show success message even without network info")
        end)

        it("still shows device name", function()
            package.loaded["device"] = {
                isKindle = function() return false end,
                retrieveNetworkInfo = nil,
            }

            create_instance_and_start()

            local found_device = false
            for _, n in ipairs(notifications_shown) do
                -- New format: "LocalSend Ready - KOReader | ..."
                if n.text and n.text:match("KOReader") then
                    found_device = true
                    break
                end
            end
            assert.is_true(found_device, "Should show device name in notification")
        end)
    end)

    describe("when retrieveNetworkInfo returns empty string", function()
        it("shows success notification without network section", function()
            package.loaded["device"] = {
                isKindle = function() return false end,
                retrieveNetworkInfo = function() return "" end,
            }

            create_instance_and_start()

            local found_success = false
            for _, n in ipairs(notifications_shown) do
                if n.text and n.text:match("LocalSend Ready") then
                    found_success = true
                    break
                end
            end
            assert.is_true(found_success, "Should still show success notification")
        end)
    end)

    describe("when Device module is completely missing", function()
        it("handles gracefully if Device global is missing", function()
            package.loaded["device"] = {
                isKindle = function() return false end,
                -- No retrieveNetworkInfo at all
            }

            create_instance_and_start()

            -- Should still show success
            local found_success = false
            for _, n in ipairs(notifications_shown) do
                if n.text and n.text:match("LocalSend Ready") then
                    found_success = true
                    break
                end
            end
            assert.is_true(found_success, "Should show success message even without network function")
        end)
    end)

    describe("notification content structure", function()
        it("includes device name in notification", function()
            package.loaded["device"] = {
                isKindle = function() return false end,
                retrieveNetworkInfo = function() return "WiFi" end,
            }

            create_instance_and_start()

            local found_device = false
            for _, n in ipairs(notifications_shown) do
                -- New format: "LocalSend Ready - KOReader | ..."
                if n.text and n.text:match("KOReader") then
                    found_device = true
                    break
                end
            end
            assert.is_true(found_device, "Should mention device name in notification")
        end)

        it("shows default device name 'KOReader' when not configured", function()
            package.loaded["device"] = {
                isKindle = function() return false end,
                retrieveNetworkInfo = function() return "WiFi" end,
            }

            create_instance_and_start()

            local found_koreader = false
            for _, n in ipairs(notifications_shown) do
                if n.text and n.text:match("KOReader") then
                    found_koreader = true
                    break
                end
            end
            assert.is_true(found_koreader, "Should show 'KOReader' as default device name")
        end)

        it("shows custom device name when configured", function()
            settings["LocalSend_device_name"] = "My Kindle"
            package.loaded["device"] = {
                isKindle = function() return false end,
                retrieveNetworkInfo = function() return "WiFi" end,
            }

            create_instance_and_start()

            local found_custom = false
            for _, n in ipairs(notifications_shown) do
                if n.text and n.text:match("My Kindle") then
                    found_custom = true
                    break
                end
            end
            assert.is_true(found_custom, "Should show custom device name")
        end)

        it("has timeout on success notification", function()
            package.loaded["device"] = {
                isKindle = function() return false end,
                retrieveNetworkInfo = function() return "WiFi" end,
            }

            create_instance_and_start()

            local found_timeout = false
            for _, n in ipairs(notifications_shown) do
                if n.text and n.text:match("LocalSend Ready") and n.timeout then
                    found_timeout = true
                    assert.is_true(n.timeout > 0, "Timeout should be positive")
                    break
                end
            end
            assert.is_true(found_timeout, "Success notification should have timeout")
        end)

        it("shows PIN status when PIN is configured", function()
            settings["LocalSend_pin"] = "1234"
            package.loaded["device"] = {
                isKindle = function() return false end,
                retrieveNetworkInfo = function() return "WiFi" end,
            }

            create_instance_and_start()

            local found_pin = false
            for _, n in ipairs(notifications_shown) do
                if n.text and n.text:match("PIN") then
                    found_pin = true
                    break
                end
            end
            assert.is_true(found_pin, "Should show PIN status when PIN is set")
        end)

        it("does not show PIN status when PIN is not configured", function()
            settings["LocalSend_pin"] = nil
            package.loaded["device"] = {
                isKindle = function() return false end,
                retrieveNetworkInfo = function() return "WiFi" end,
            }

            create_instance_and_start()

            local found_pin = false
            for _, n in ipairs(notifications_shown) do
                if n.text and n.text:match("LocalSend Ready") then
                    if n.text:match("PIN") then
                        found_pin = true
                    end
                    break
                end
            end
            assert.is_false(found_pin, "Should not show PIN status when PIN is not set")
        end)
    end)
end)
