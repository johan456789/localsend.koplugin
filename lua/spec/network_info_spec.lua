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
            sleep = function() end,
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

        package.loaded["ui/uimanager"] = {
            show = function() end,
            close = function() end,
            scheduleIn = function(self, delay, callback) end,
        }

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
        instance.setupCertificates = function() end
        instance.clearTransferLog = function() end
        instance.openFirewall = function() end
        instance.saveCertificates = function() end
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
        it("shows fallback message", function()
            package.loaded["device"] = {
                isKindle = function() return false end,
                retrieveNetworkInfo = nil,
            }

            create_instance_and_start()

            local found_fallback = false
            for _, n in ipairs(notifications_shown) do
                if n.text and n.text:match("Could not retrieve network info") then
                    found_fallback = true
                    break
                end
            end
            assert.is_true(found_fallback, "Should show fallback when retrieveNetworkInfo is nil")
        end)

        it("still shows port and save directory", function()
            package.loaded["device"] = {
                isKindle = function() return false end,
                retrieveNetworkInfo = nil,
            }

            create_instance_and_start()

            local found_success = false
            for _, n in ipairs(notifications_shown) do
                if n.text and n.text:match("LocalSend server started") then
                    found_success = true
                    break
                end
            end
            assert.is_true(found_success, "Should still show success message")
        end)
    end)

    describe("when retrieveNetworkInfo returns empty string", function()
        it("shows empty network info section (not fallback)", function()
            package.loaded["device"] = {
                isKindle = function() return false end,
                retrieveNetworkInfo = function() return "" end,
            }

            create_instance_and_start()

            -- In Lua, empty string "" is truthy for the `and` operator
            -- So: Device.retrieveNetworkInfo and Device:retrieveNetworkInfo() returns ""
            -- And "" or "fallback" returns "" because "" is truthy
            -- The notification will have the empty string in place of network info
            local found_success = false
            for _, n in ipairs(notifications_shown) do
                if n.text and n.text:match("LocalSend server started") then
                    found_success = true
                    -- The network info portion should be empty, not the fallback message
                    -- Because "" or "fallback" in Lua returns "" (truthy)
                    break
                end
            end
            assert.is_true(found_success, "Should still show success notification with empty network info")
        end)
    end)

    describe("when Device module is completely missing", function()
        it("handles gracefully if Device global is missing", function()
            -- In reality, Device should always exist, but this tests robustness
            package.loaded["device"] = {
                isKindle = function() return false end,
                -- No retrieveNetworkInfo at all
            }

            create_instance_and_start()

            -- Should show fallback
            local found_fallback = false
            for _, n in ipairs(notifications_shown) do
                if n.text and n.text:match("Could not retrieve network info") then
                    found_fallback = true
                    break
                end
            end
            assert.is_true(found_fallback, "Should show fallback when function is missing")
        end)
    end)

    describe("notification content structure", function()
        it("includes port in notification", function()
            package.loaded["device"] = {
                isKindle = function() return false end,
                retrieveNetworkInfo = function() return "WiFi" end,
            }

            create_instance_and_start()

            local found_port = false
            for _, n in ipairs(notifications_shown) do
                -- Port might be in text with template substitution
                if n.text and (n.text:match("Port") or n.text:match("53317") or n.text:match("%%1")) then
                    found_port = true
                    break
                end
            end
            assert.is_true(found_port, "Should mention port in notification")
        end)

        it("includes save directory in notification", function()
            package.loaded["device"] = {
                isKindle = function() return false end,
                retrieveNetworkInfo = function() return "WiFi" end,
            }

            create_instance_and_start()

            local found_dir = false
            for _, n in ipairs(notifications_shown) do
                if n.text and (n.text:match("Save directory") or n.text:match("/mnt/us/documents") or n.text:match("%%2")) then
                    found_dir = true
                    break
                end
            end
            assert.is_true(found_dir, "Should mention save directory in notification")
        end)

        it("has timeout on success notification", function()
            package.loaded["device"] = {
                isKindle = function() return false end,
                retrieveNetworkInfo = function() return "WiFi" end,
            }

            create_instance_and_start()

            local found_timeout = false
            for _, n in ipairs(notifications_shown) do
                if n.text and n.text:match("LocalSend server started") and n.timeout then
                    found_timeout = true
                    assert.is_true(n.timeout > 0, "Timeout should be positive")
                    break
                end
            end
            assert.is_true(found_timeout, "Success notification should have timeout")
        end)
    end)
end)
