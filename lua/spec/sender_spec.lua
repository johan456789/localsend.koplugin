require 'busted.runner'()

describe("localsend_sender", function()
    local helper = require("spec.test_helper")

    -- Setup before all tests in this file
    setup(function()
        helper.setup_complete()
        helper.mock_os_execute()
        helper.mock_os_remove()
    end)

    before_each(function()
        helper.reset_state()
        helper.reset_localsend_state()
    end)

    describe("isSendInProgress", function()
        local sender

        before_each(function()
            package.loaded["localsend_sender"] = nil
            sender = require("localsend_sender")
            sender.init({
                UIManager = package.loaded["ui/uimanager"],
                InfoMessage = package.loaded["ui/widget/infomessage"],
                Notification = package.loaded["ui/widget/notification"],
                InputDialog = package.loaded["ui/widget/inputdialog"],
                ButtonDialog = package.loaded["ui/widget/buttondialog"],
                PathChooser = package.loaded["ui/widget/pathchooser"],
                NetworkMgr = package.loaded["ui/network/manager"],
                util = package.loaded["util"],
                json = package.loaded["json"],
                logger = package.loaded["logger"],
                T = require("ffi/util").template,
                _ = require("gettext"),
            }, {
                binary_path = "/tmp/localsend",
            })
        end)

        it("returns false when no send in progress", function()
            assert.is_false(sender.isSendInProgress())
        end)

        it("returns true when send is in progress", function()
            local state = require("localsend_state")
            state.ServerState.send_in_progress = true
            assert.is_true(sender.isSendInProgress())
        end)
    end)

    describe("sendFile", function()
        local sender

        before_each(function()
            package.loaded["localsend_sender"] = nil
            sender = require("localsend_sender")
            -- Mock pathExists to return true for test files
            package.loaded["util"].pathExists = function(path)
                if path == "/test/file.epub" then return true end
                if path:match("^/proc/") then return false end
                return false
            end
            sender.init({
                UIManager = package.loaded["ui/uimanager"],
                InfoMessage = package.loaded["ui/widget/infomessage"],
                Notification = package.loaded["ui/widget/notification"],
                InputDialog = package.loaded["ui/widget/inputdialog"],
                ButtonDialog = package.loaded["ui/widget/buttondialog"],
                PathChooser = package.loaded["ui/widget/pathchooser"],
                NetworkMgr = package.loaded["ui/network/manager"],
                util = package.loaded["util"],
                json = package.loaded["json"],
                logger = package.loaded["logger"],
                T = require("ffi/util").template,
                _ = require("gettext"),
            }, {
                binary_path = "/tmp/localsend",
            })
        end)

        it("blocks concurrent sends", function()
            local state = require("localsend_state")
            state.ServerState.send_in_progress = true

            local callback_called = false
            local callback_success = true
            local callback_msg = ""

            sender.sendFile(
                { type = "lan", ip = "192.168.1.50", alias = "Phone" },
                "/test/file.epub",
                nil,
                function(success, msg)
                    callback_called = true
                    callback_success = success
                    callback_msg = msg
                end
            )

            assert.is_true(callback_called)
            assert.is_false(callback_success)
            assert.truthy(callback_msg:match("in progress"))
        end)

        it("fails for nonexistent file", function()
            local callback_called = false
            local callback_success = true

            sender.sendFile(
                { type = "lan", ip = "192.168.1.50", alias = "Phone" },
                "/nonexistent/file.epub",
                nil,
                function(success, msg)
                    callback_called = true
                    callback_success = success
                end
            )

            assert.is_true(callback_called)
            assert.is_false(callback_success)
        end)

        it("builds correct command for LAN device", function()
            sender.sendFile(
                { type = "lan", ip = "192.168.1.50", protocol = "https", alias = "Phone" },
                "/test/file.epub",
                nil,
                nil
            )

            -- Check that os.execute was called with the right command
            assert.is_true(#helper.state.os_execute_calls > 0)
            local cmd = helper.state.os_execute_calls[1]
            assert.truthy(cmd:match("send"))
            assert.truthy(cmd:match("%-%-ip"))
            assert.truthy(cmd:match("192%.168%.1%.50"))
            assert.truthy(cmd:match("%-%-https"))
        end)

        it("builds correct command for WebRTC device", function()
            sender.sendFile(
                { type = "webrtc", id = "abc-123", alias = "Browser" },
                "/test/file.epub",
                nil,
                nil
            )

            assert.is_true(#helper.state.os_execute_calls > 0)
            local cmd = helper.state.os_execute_calls[1]
            assert.truthy(cmd:match("send"))
            assert.truthy(cmd:match("%-%-webrtc"))
            assert.truthy(cmd:match("%-%-target"))
            assert.truthy(cmd:match("abc%-123"))
        end)

        it("includes PIN in command when provided", function()
            sender.sendFile(
                { type = "lan", ip = "192.168.1.50", protocol = "https", alias = "Phone" },
                "/test/file.epub",
                "1234",
                nil
            )

            assert.is_true(#helper.state.os_execute_calls > 0)
            local cmd = helper.state.os_execute_calls[1]
            assert.truthy(cmd:match("%-p"))
            assert.truthy(cmd:match("1234"))
        end)

        it("sets send_in_progress flag", function()
            local state = require("localsend_state")
            assert.is_false(state.ServerState.send_in_progress)

            sender.sendFile(
                { type = "lan", ip = "192.168.1.50", protocol = "https", alias = "Phone" },
                "/test/file.epub",
                nil,
                nil
            )

            assert.is_true(state.ServerState.send_in_progress)
        end)
    end)

    describe("cancelSend", function()
        local sender

        before_each(function()
            package.loaded["localsend_sender"] = nil
            sender = require("localsend_sender")
            sender.init({
                UIManager = package.loaded["ui/uimanager"],
                InfoMessage = package.loaded["ui/widget/infomessage"],
                Notification = package.loaded["ui/widget/notification"],
                InputDialog = package.loaded["ui/widget/inputdialog"],
                ButtonDialog = package.loaded["ui/widget/buttondialog"],
                PathChooser = package.loaded["ui/widget/pathchooser"],
                NetworkMgr = package.loaded["ui/network/manager"],
                util = package.loaded["util"],
                json = package.loaded["json"],
                logger = package.loaded["logger"],
                T = require("ffi/util").template,
                _ = require("gettext"),
            }, {
                binary_path = "/tmp/localsend",
            })
        end)

        it("clears send_in_progress flag", function()
            local state = require("localsend_state")
            state.ServerState.send_in_progress = true

            sender.cancelSend()

            assert.is_false(state.ServerState.send_in_progress)
        end)
    end)

    describe("showFileSendFlow", function()
        local sender

        before_each(function()
            package.loaded["localsend_sender"] = nil
            sender = require("localsend_sender")
            sender.init({
                UIManager = package.loaded["ui/uimanager"],
                InfoMessage = package.loaded["ui/widget/infomessage"],
                Notification = package.loaded["ui/widget/notification"],
                InputDialog = package.loaded["ui/widget/inputdialog"],
                ButtonDialog = package.loaded["ui/widget/buttondialog"],
                PathChooser = package.loaded["ui/widget/pathchooser"],
                NetworkMgr = package.loaded["ui/network/manager"],
                util = package.loaded["util"],
                json = package.loaded["json"],
                logger = package.loaded["logger"],
                T = require("ffi/util").template,
                _ = require("gettext"),
            }, {
                binary_path = "/tmp/localsend",
            })
        end)

        it("blocks when send already in progress", function()
            local state = require("localsend_state")
            state.ServerState.send_in_progress = true

            sender.showFileSendFlow({ getPickerStartPath = function(_, path) return path end })

            local notification = helper.find_notification("in progress")
            assert.is_not_nil(notification)
        end)

        it("starts device scan when network connected", function()
            sender.showFileSendFlow({ getPickerStartPath = function(_, path) return path end })

            -- Should have executed scan command
            assert.is_true(#helper.state.os_execute_calls > 0)
            local cmd = helper.state.os_execute_calls[1]
            assert.truthy(cmd:match("scan"))
            assert.truthy(cmd:match("%-%-json"))
        end)

        it("uses willRerunWhenConnected to avoid duplicate flow when offline", function()
            local rerun_called = false
            local scan_called = false
            package.loaded["ui/network/manager"] = {
                isConnected = function() return false end,
                willRerunWhenConnected = function(self, callback)
                    rerun_called = true
                    return true
                end,
                runWhenConnected = function(self, callback)
                    scan_called = true
                    if callback then callback() end
                end,
            }

            sender.init({
                UIManager = package.loaded["ui/uimanager"],
                InfoMessage = package.loaded["ui/widget/infomessage"],
                Notification = package.loaded["ui/widget/notification"],
                InputDialog = package.loaded["ui/widget/inputdialog"],
                ButtonDialog = package.loaded["ui/widget/buttondialog"],
                PathChooser = package.loaded["ui/widget/pathchooser"],
                NetworkMgr = package.loaded["ui/network/manager"],
                util = package.loaded["util"],
                json = package.loaded["json"],
                logger = package.loaded["logger"],
                T = require("ffi/util").template,
                _ = require("gettext"),
            }, {
                binary_path = "/tmp/localsend",
            })

            sender.showFileSendFlow({ getPickerStartPath = function(_, path) return path end })

            assert.is_true(rerun_called)
            assert.is_false(scan_called)
            assert.equals(0, #helper.state.os_execute_calls)
        end)
    end)

    -- =============================================================================
    -- Error Categorization Tests
    -- =============================================================================

    describe("error categorization", function()
        local sender

        before_each(function()
            package.loaded["localsend_sender"] = nil
            sender = require("localsend_sender")
            sender.init({
                UIManager = package.loaded["ui/uimanager"],
                InfoMessage = package.loaded["ui/widget/infomessage"],
                Notification = package.loaded["ui/widget/notification"],
                InputDialog = package.loaded["ui/widget/inputdialog"],
                ButtonDialog = package.loaded["ui/widget/buttondialog"],
                PathChooser = package.loaded["ui/widget/pathchooser"],
                NetworkMgr = package.loaded["ui/network/manager"],
                util = package.loaded["util"],
                json = package.loaded["json"],
                logger = package.loaded["logger"],
                T = require("ffi/util").template,
                _ = require("gettext"),
            }, {
                binary_path = "/tmp/localsend",
            })
        end)

        it("categorizeError identifies PIN required errors", function()
            local category = sender.categorizeError("error: PIN required (401)")
            assert.equals("pin_required", category)
        end)

        it("categorizeError identifies wrong PIN errors", function()
            local category = sender.categorizeError("error: wrong PIN")
            assert.equals("wrong_pin", category)
        end)

        it("categorizeError identifies rejected errors", function()
            local category = sender.categorizeError("error: transfer rejected by receiver")
            assert.equals("rejected", category)
        end)

        it("categorizeError identifies connection refused (device not running)", function()
            local category = sender.categorizeError("error: connection refused")
            assert.equals("connection_refused", category)
        end)

        it("categorizeError identifies generic connection errors", function()
            local category = sender.categorizeError("error: connection reset by peer")
            assert.equals("connection", category)
        end)

        it("categorizeError identifies rate limiting", function()
            local category = sender.categorizeError("error: too many attempts")
            assert.equals("rate_limited", category)
        end)

        it("categorizeError identifies timeout errors", function()
            local category = sender.categorizeError("error: timeout waiting for response")
            assert.equals("timeout", category)
        end)

        it("categorizeError returns unknown for unrecognized errors", function()
            local category = sender.categorizeError("error: some random error")
            assert.equals("unknown", category)
        end)

        it("categorizeError handles nil input", function()
            local category = sender.categorizeError(nil)
            assert.equals("unknown", category)
        end)

        it("categorizeError handles empty string", function()
            local category = sender.categorizeError("")
            assert.equals("unknown", category)
        end)
    end)

    describe("PIN dialog flow", function()
        local sender

        before_each(function()
            package.loaded["localsend_sender"] = nil
            sender = require("localsend_sender")
            sender.init({
                UIManager = package.loaded["ui/uimanager"],
                InfoMessage = package.loaded["ui/widget/infomessage"],
                Notification = package.loaded["ui/widget/notification"],
                InputDialog = package.loaded["ui/widget/inputdialog"],
                ButtonDialog = package.loaded["ui/widget/buttondialog"],
                PathChooser = package.loaded["ui/widget/pathchooser"],
                NetworkMgr = package.loaded["ui/network/manager"],
                util = package.loaded["util"],
                json = package.loaded["json"],
                logger = package.loaded["logger"],
                T = require("ffi/util").template,
                _ = require("gettext"),
            }, {
                binary_path = "/tmp/localsend",
            })
        end)

        it("showPINDialog shows input dialog", function()
            local callback_called = false
            sender.showPINDialog({ alias = "Test Device" }, function(pin)
                callback_called = true
            end)

            local dialog = helper.find_dialog("InputDialog")
            assert.is_not_nil(dialog)
            assert.truthy(dialog.title:match("PIN"))
        end)

        it("showPINDialog includes device name in title", function()
            sender.showPINDialog({ alias = "iPhone" }, function(pin) end)

            local dialog = helper.find_dialog("InputDialog")
            assert.is_not_nil(dialog)
            assert.truthy(dialog.title:match("iPhone"))
        end)
    end)
end)
