require 'busted.runner'()

describe("localsend_discovery", function()
    local helper = require("spec.test_helper")

    -- Setup before all tests in this file
    setup(function()
        helper.setup_complete({
            json = {
                decode = function(s)
                    -- Simple JSON parser for tests
                    if not s or s == "" then return nil end
                    -- Use loadstring to parse JSON-like Lua tables for testing
                    local fn = loadstring("return " .. s:gsub('([%w_]+):', '["%1"]='):gsub('%[', '{'):gsub('%]', '}'))
                    if fn then
                        return fn()
                    end
                    return nil
                end,
            },
        })
    end)

    before_each(function()
        helper.reset_state()
        helper.reset_localsend_state()
    end)

    describe("parseDevices", function()
        local discovery

        before_each(function()
            package.loaded["localsend_discovery"] = nil
            discovery = require("localsend_discovery")
            discovery.init({
                UIManager = package.loaded["ui/uimanager"],
                InfoMessage = package.loaded["ui/widget/infomessage"],
                Notification = package.loaded["ui/widget/notification"],
                ButtonDialog = package.loaded["ui/widget/buttondialog"],
                util = package.loaded["util"],
                json = require("json"),
                logger = package.loaded["logger"],
                T = require("ffi/util").template,
                _ = require("gettext"),
            }, {
                binary_path = "/tmp/localsend",
            })
        end)

        it("returns empty array for nil input", function()
            local devices = discovery.parseDevices(nil)
            assert.are.same({}, devices)
        end)

        it("returns empty array for empty string", function()
            local devices = discovery.parseDevices("")
            assert.are.same({}, devices)
        end)

        it("returns empty array for invalid JSON", function()
            local devices = discovery.parseDevices("not valid json")
            assert.are.same({}, devices)
        end)

        it("parses LAN devices from JSON", function()
            -- Mock proper JSON decode
            local json_mock = {
                decode = function(s)
                    return {
                        lan = {
                            { ip = "192.168.1.50", port = 53317, alias = "iPhone", version = "2.1", protocol = "https" },
                        },
                        webrtc = {},
                    }
                end,
            }
            package.loaded["json"] = json_mock
            package.loaded["localsend_discovery"] = nil
            discovery = require("localsend_discovery")
            discovery.init({
                UIManager = package.loaded["ui/uimanager"],
                InfoMessage = package.loaded["ui/widget/infomessage"],
                Notification = package.loaded["ui/widget/notification"],
                ButtonDialog = package.loaded["ui/widget/buttondialog"],
                util = package.loaded["util"],
                json = json_mock,
                logger = package.loaded["logger"],
                T = require("ffi/util").template,
                _ = require("gettext"),
            }, {
                binary_path = "/tmp/localsend",
            })

            local devices = discovery.parseDevices('{"lan":[{"ip":"192.168.1.50"}]}')
            assert.equals(1, #devices)
            assert.equals("lan", devices[1].type)
            assert.equals("iPhone", devices[1].alias)
            assert.equals("192.168.1.50", devices[1].ip)
            assert.equals(53317, devices[1].port)
            assert.equals("https", devices[1].protocol)
        end)

        it("parses WebRTC devices from JSON", function()
            local json_mock = {
                decode = function(s)
                    return {
                        lan = {},
                        webrtc = {
                            { id = "abc-123", alias = "Browser", version = "2.1" },
                        },
                    }
                end,
            }
            package.loaded["json"] = json_mock
            package.loaded["localsend_discovery"] = nil
            discovery = require("localsend_discovery")
            discovery.init({
                UIManager = package.loaded["ui/uimanager"],
                InfoMessage = package.loaded["ui/widget/infomessage"],
                Notification = package.loaded["ui/widget/notification"],
                ButtonDialog = package.loaded["ui/widget/buttondialog"],
                util = package.loaded["util"],
                json = json_mock,
                logger = package.loaded["logger"],
                T = require("ffi/util").template,
                _ = require("gettext"),
            }, {
                binary_path = "/tmp/localsend",
            })

            local devices = discovery.parseDevices('{"webrtc":[{"id":"abc-123"}]}')
            assert.equals(1, #devices)
            assert.equals("webrtc", devices[1].type)
            assert.equals("Browser", devices[1].alias)
            assert.equals("abc-123", devices[1].id)
        end)

        it("parses mixed LAN and WebRTC devices", function()
            local json_mock = {
                decode = function(s)
                    return {
                        lan = {
                            { ip = "192.168.1.50", port = 53317, alias = "Phone", version = "2.1", protocol = "https" },
                        },
                        webrtc = {
                            { id = "abc-123", alias = "Browser", version = "2.1" },
                        },
                    }
                end,
            }
            package.loaded["json"] = json_mock
            package.loaded["localsend_discovery"] = nil
            discovery = require("localsend_discovery")
            discovery.init({
                UIManager = package.loaded["ui/uimanager"],
                InfoMessage = package.loaded["ui/widget/infomessage"],
                Notification = package.loaded["ui/widget/notification"],
                ButtonDialog = package.loaded["ui/widget/buttondialog"],
                util = package.loaded["util"],
                json = json_mock,
                logger = package.loaded["logger"],
                T = require("ffi/util").template,
                _ = require("gettext"),
            }, {
                binary_path = "/tmp/localsend",
            })

            local devices = discovery.parseDevices('{}')
            assert.equals(2, #devices)
            -- LAN device first
            assert.equals("lan", devices[1].type)
            -- WebRTC device second
            assert.equals("webrtc", devices[2].type)
        end)
    end)

    describe("getDeviceDisplayText", function()
        local discovery

        before_each(function()
            package.loaded["localsend_discovery"] = nil
            discovery = require("localsend_discovery")
            discovery.init({
                UIManager = package.loaded["ui/uimanager"],
                InfoMessage = package.loaded["ui/widget/infomessage"],
                Notification = package.loaded["ui/widget/notification"],
                ButtonDialog = package.loaded["ui/widget/buttondialog"],
                util = package.loaded["util"],
                json = package.loaded["json"],
                logger = package.loaded["logger"],
                T = require("ffi/util").template,
                _ = require("gettext"),
            }, {
                binary_path = "/tmp/localsend",
            })
        end)

        it("formats LAN device with IP", function()
            local device = { type = "lan", alias = "iPhone", ip = "192.168.1.50" }
            local text = discovery.getDeviceDisplayText(device)
            assert.equals("[LAN] iPhone (192.168.1.50)", text)
        end)

        it("formats WebRTC device without IP", function()
            local device = { type = "webrtc", alias = "Browser", id = "abc-123" }
            local text = discovery.getDeviceDisplayText(device)
            assert.equals("[WebRTC] Browser", text)
        end)
    end)

    describe("getCachedDevices", function()
        local discovery

        before_each(function()
            package.loaded["localsend_discovery"] = nil
            discovery = require("localsend_discovery")
            discovery.init({
                UIManager = package.loaded["ui/uimanager"],
                InfoMessage = package.loaded["ui/widget/infomessage"],
                Notification = package.loaded["ui/widget/notification"],
                ButtonDialog = package.loaded["ui/widget/buttondialog"],
                util = package.loaded["util"],
                json = package.loaded["json"],
                logger = package.loaded["logger"],
                T = require("ffi/util").template,
                _ = require("gettext"),
            }, {
                binary_path = "/tmp/localsend",
            })
        end)

        it("returns empty array when no devices cached", function()
            local devices = discovery.getCachedDevices()
            assert.are.same({}, devices)
        end)

        it("returns cached devices from ServerState", function()
            local state = require("localsend_state")
            state.ServerState.discovered_devices = {
                { type = "lan", alias = "Phone", ip = "192.168.1.50" },
            }
            local devices = discovery.getCachedDevices()
            assert.equals(1, #devices)
            assert.equals("Phone", devices[1].alias)
        end)
    end)

    describe("showDeviceSelector", function()
        local discovery

        before_each(function()
            package.loaded["localsend_discovery"] = nil
            discovery = require("localsend_discovery")
            discovery.init({
                UIManager = package.loaded["ui/uimanager"],
                InfoMessage = package.loaded["ui/widget/infomessage"],
                Notification = package.loaded["ui/widget/notification"],
                ButtonDialog = package.loaded["ui/widget/buttondialog"],
                util = package.loaded["util"],
                json = package.loaded["json"],
                logger = package.loaded["logger"],
                T = require("ffi/util").template,
                _ = require("gettext"),
            }, {
                binary_path = "/tmp/localsend",
            })
        end)

        it("shows info message when no devices found", function()
            local callback_called = false
            local callback_device = "not_nil"

            discovery.showDeviceSelector({}, function(device)
                callback_called = true
                callback_device = device
            end)

            assert.is_true(callback_called)
            assert.is_nil(callback_device)
            assert.equals(1, #helper.state.notifications_shown)
            assert.truthy(helper.state.notifications_shown[1].text:match("No devices found"))
        end)

        it("shows button dialog for available devices", function()
            local devices = {
                { type = "lan", alias = "Phone", ip = "192.168.1.50" },
            }

            discovery.showDeviceSelector(devices, function(device) end)

            local dialog = helper.find_dialog("ButtonDialog")
            assert.is_not_nil(dialog)
            assert.equals("Select target device", dialog.title)
        end)
    end)

    -- =============================================================================
    -- Scan Timeout Tests
    -- =============================================================================

    describe("scan timeout behavior", function()
        local discovery
        local constants

        before_each(function()
            package.loaded["localsend_discovery"] = nil
            package.loaded["localsend_constants"] = nil
            discovery = require("localsend_discovery")
            constants = require("localsend_constants")
            discovery.init({
                UIManager = package.loaded["ui/uimanager"],
                InfoMessage = package.loaded["ui/widget/infomessage"],
                Notification = package.loaded["ui/widget/notification"],
                ButtonDialog = package.loaded["ui/widget/buttondialog"],
                util = package.loaded["util"],
                json = package.loaded["json"],
                logger = package.loaded["logger"],
                T = require("ffi/util").template,
                _ = require("gettext"),
            }, {
                binary_path = "/tmp/localsend",
            })
        end)

        it("SCAN_MAX_POLL_DURATION is defined", function()
            assert.is_not_nil(constants.SCAN_MAX_POLL_DURATION)
            assert.is_number(constants.SCAN_MAX_POLL_DURATION)
        end)

        it("SCAN_MAX_POLL_DURATION has reasonable value (5-120 seconds)", function()
            -- Scan should timeout within reasonable bounds
            assert.is_true(constants.SCAN_MAX_POLL_DURATION >= 5)
            assert.is_true(constants.SCAN_MAX_POLL_DURATION <= 120)
        end)

        it("SCAN_POLL_INTERVAL is defined", function()
            assert.is_not_nil(constants.SCAN_POLL_INTERVAL)
            assert.is_number(constants.SCAN_POLL_INTERVAL)
        end)
    end)
end)
