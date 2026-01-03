require 'busted.runner'()

-- Tests for certificate management: rotateCertificates
-- Note: setupCertificates and saveCertificates have been removed.
-- Go now manages certificates directly in a certs/ folder next to the binary.

describe("Certificate Management", function()
    local LocalSend
    local os_execute_calls
    local path_exists_map
    local notifications_shown

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
            retrieveNetworkInfo = function() return "WiFi" end,
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
        package.loaded["json"] = {
            encode = function(t) return "{}" end,
            decode = function(s) return {} end,
        }

        _G.dofile = function(path)
            if path:match("_meta%.lua$") then
                return { version = "v1.1.1" }
            end
        end
    end)

    before_each(function()
        os_execute_calls = {}
        path_exists_map = {
            ["/tmp/koreader/plugins/localsend.koplugin"] = true,
            ["/tmp/koreader/plugins/localsend.koplugin/localsend"] = true,
        }
        notifications_shown = {}

        _G.G_reader_settings = {
            readSetting = function() return nil end,
            saveSetting = function() end,
            isTrue = function() return false end,
            nilOrTrue = function() return true end,
            flipNilOrTrue = function() end,
            flipNilOrFalse = function() end,
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
                if path_exists_map[path] ~= nil then
                    return path_exists_map[path]
                end
                return false
            end,
            makePath = function(path)
                -- Track makePath calls via os_execute_calls for test compatibility
                table.insert(os_execute_calls, "'mkdir' '-p' '" .. path .. "'")
                return true
            end,
            readFromFile = function(path)
                return nil
            end,
            splitFilePathName = function(file)
                if file == nil or file == "" then return "", "" end
                if not file:find("/") then return "", file end
                return file:match("(.*/)(.*)$")
            end,
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
            scheduleIn = function() end,
        }

        _G.os.execute = function(cmd)
            table.insert(os_execute_calls, cmd)
            return 0
        end

        package.loaded["localsend_utils"] = require("localsend_utils")
        package.loaded["main"] = nil
    end)

    describe("rotateCertificates", function()
        it("should remove certificates from certs folder", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            os_execute_calls = {}
            instance:rotateCertificates()

            local found_rm_key = false
            local found_rm_crt = false
            for _, cmd in ipairs(os_execute_calls) do
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

        it("should show notification about certificate rotation", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            notifications_shown = {}
            instance:rotateCertificates()

            local found_notification = false
            for _, n in ipairs(notifications_shown) do
                if n.text and n.text:match("Certificates cleared") then
                    found_notification = true
                    break
                end
            end
            assert.is_true(found_notification, "Should show rotation notification")
        end)

        it("notification should mention new certificates will be generated", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            notifications_shown = {}
            instance:rotateCertificates()

            local found_regen_msg = false
            for _, n in ipairs(notifications_shown) do
                if n.text and n.text:match("generated on next start") then
                    found_regen_msg = true
                    break
                end
            end
            assert.is_true(found_regen_msg, "Should mention regeneration on next start")
        end)
    end)
end)
