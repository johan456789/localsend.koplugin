require 'busted.runner'()
local helper = require("spec.test_helper")

-- Tests for certificate management and restart functionality
-- Note: setupCertificates and saveCertificates have been removed.
-- Go now manages certificates directly in a certs/ folder next to the binary.

describe("Certificate Management", function()
    setup(function()
        helper.setup_complete()
    end)

    before_each(function()
        helper.before_each()
        helper.mock_os_execute()
    end)

    describe("rotateCertificates", function()
        it("should remove certificates from certs folder", function()
            local instance = helper.create_instance()

            instance:rotateCertificates()

            local found_rm_key = false
            local found_rm_crt = false
            for _, cmd in ipairs(helper.state.os_execute_calls) do
                if cmd:match("'rm' '%-f'") then
                    if cmd:match("certs/server%.key%.pem") then
                        found_rm_key = true
                    end
                    if cmd:match("certs/server%.crt") then
                        found_rm_crt = true
                    end
                end
            end
            assert.is_true(found_rm_key, "Should remove key from certs folder")
            assert.is_true(found_rm_crt, "Should remove cert from certs folder")
        end)

        it("should remove exactly 2 certificate files", function()
            local instance = helper.create_instance()

            instance:rotateCertificates()

            local rm_count = 0
            for _, cmd in ipairs(helper.state.os_execute_calls) do
                if cmd:match("^'rm' '%-f'") then rm_count = rm_count + 1 end
            end
            assert.equal(2, rm_count, "Should remove 2 certificate files")
        end)

        it("should show notification about certificate rotation", function()
            local instance = helper.create_instance()

            instance:rotateCertificates()

            local notification = helper.find_notification("Certificates cleared")
            assert.is_truthy(notification, "Should show rotation notification")
        end)

        it("notification should mention new certificates will be generated", function()
            local instance = helper.create_instance()

            instance:rotateCertificates()

            local notification = helper.find_notification("generated on next start")
            assert.is_truthy(notification, "Should mention regeneration on next start")
        end)

        it("notification should have timeout", function()
            local instance = helper.create_instance()

            instance:rotateCertificates()

            assert.equal(3, helper.state.notifications_shown[1].timeout)
        end)
    end)

    describe("restart", function()
        it("stops server then starts when running", function()
            local instance = helper.create_instance()

            local stop_called = false
            local start_called = false
            local stop_called_first = false

            instance.isRunning = function() return true end
            instance.stopServer = function(self, silent)
                stop_called = true
                if not start_called then stop_called_first = true end
            end
            instance.start = function() start_called = true end

            instance:restart()

            assert.is_true(stop_called, "Should call stopServer")
            assert.is_true(start_called, "Should call start")
            assert.is_true(stop_called_first, "Should stop before starting")
        end)

        it("only starts when not running", function()
            local instance = helper.create_instance()

            local stop_called = false
            local start_called = false

            instance.isRunning = function() return false end
            instance.stopServer = function(self, silent) stop_called = true end
            instance.start = function() start_called = true end

            instance:restart()

            assert.is_false(stop_called, "Should not call stopServer when not running")
            assert.is_true(start_called, "Should call start")
        end)
    end)
end)
