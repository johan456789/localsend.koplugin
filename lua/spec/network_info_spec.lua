require 'busted.runner'()
local helper = require("spec.test_helper")

-- Tests for network info display in server start notification

describe("Network Info Display", function()
    setup(function()
        helper.setup_complete()
    end)

    before_each(function()
        helper.before_each()

        -- Override pathExists for write test
        local base_pathExists = package.loaded["util"].pathExists
        package.loaded["util"].pathExists = function(path)
            if path == "/mnt/us/documents" then return true end
            return base_pathExists(path)
        end

        -- Mock io.open for write test
        local original_io_open = io.open
        _G.io.open = function(path, mode)
            if mode == "w" and path:match("%.localsend_write_test$") then
                return { close = function() end }
            end
            return original_io_open(path, mode)
        end

        package.loaded["device"] = nil
    end)

    local function create_instance_and_start()
        local LocalSend = require("main")
        local instance = helper.create_instance()
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

        helper.state.notifications_shown = {}
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
            for _, n in ipairs(helper.state.notifications_shown) do
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
            for _, n in ipairs(helper.state.notifications_shown) do
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
            for _, n in ipairs(helper.state.notifications_shown) do
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
            for _, n in ipairs(helper.state.notifications_shown) do
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
            for _, n in ipairs(helper.state.notifications_shown) do
                if n.text and n.text:match("LocalSend Ready") then
                    found_success = true
                    break
                end
            end
            assert.is_true(found_success, "Should still show success notification")
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
            for _, n in ipairs(helper.state.notifications_shown) do
                if n.text and n.text:match("KOReader") then
                    found_device = true
                    break
                end
            end
            assert.is_true(found_device, "Should mention device name in notification")
        end)

        it("shows custom device name when configured", function()
            helper.state.settings["LocalSend_device_name"] = "My Kindle"
            package.loaded["device"] = {
                isKindle = function() return false end,
                retrieveNetworkInfo = function() return "WiFi" end,
            }

            create_instance_and_start()

            local found_custom = false
            for _, n in ipairs(helper.state.notifications_shown) do
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
            for _, n in ipairs(helper.state.notifications_shown) do
                if n.text and n.text:match("LocalSend Ready") and n.timeout then
                    found_timeout = true
                    assert.is_true(n.timeout > 0, "Timeout should be positive")
                    break
                end
            end
            assert.is_true(found_timeout, "Success notification should have timeout")
        end)

        it("shows PIN status when PIN is configured", function()
            helper.state.settings["LocalSend_pin"] = "1234"
            package.loaded["device"] = {
                isKindle = function() return false end,
                retrieveNetworkInfo = function() return "WiFi" end,
            }

            create_instance_and_start()

            local found_pin = false
            for _, n in ipairs(helper.state.notifications_shown) do
                if n.text and n.text:match("PIN") then
                    found_pin = true
                    break
                end
            end
            assert.is_true(found_pin, "Should show PIN status when PIN is set")
        end)

        it("does not show PIN status when PIN is not configured", function()
            helper.state.settings["LocalSend_pin"] = nil
            package.loaded["device"] = {
                isKindle = function() return false end,
                retrieveNetworkInfo = function() return "WiFi" end,
            }

            create_instance_and_start()

            local found_pin = false
            for _, n in ipairs(helper.state.notifications_shown) do
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
