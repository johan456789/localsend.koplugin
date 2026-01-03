require 'busted.runner'()

-- Tests for certificate management: setupCertificates, saveCertificates, rotateCertificates

describe("Certificate Management", function()
    local LocalSend
    local os_execute_calls
    local path_exists_map
    local notifications_shown

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
            args = function(t)
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
            scheduleIn = function() end,
        }

        _G.os.execute = function(cmd)
            table.insert(os_execute_calls, cmd)
            return 0
        end

        package.loaded["localsend_utils"] = require("localsend_utils")
        package.loaded["main"] = nil
    end)

    describe("setupCertificates", function()
        it("should create cert storage directory if not exists", function()
            path_exists_map["/tmp/koreader/plugins/localsend.koplugin/certs"] = false

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            os_execute_calls = {}
            instance:setupCertificates()

            local found_mkdir = false
            for _, cmd in ipairs(os_execute_calls) do
                if cmd:match("'mkdir' '%-p'") and cmd:match("certs") then
                    found_mkdir = true
                    break
                end
            end
            assert.is_true(found_mkdir, "Should create certs directory")
        end)

        it("should not create directory if already exists", function()
            path_exists_map["/tmp/koreader/plugins/localsend.koplugin/certs"] = true

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            os_execute_calls = {}
            instance:setupCertificates()

            local found_mkdir = false
            for _, cmd in ipairs(os_execute_calls) do
                if cmd:match("mkdir") and cmd:match("certs") then
                    found_mkdir = true
                    break
                end
            end
            assert.is_false(found_mkdir, "Should not create directory if exists")
        end)

        it("should symlink stored certs to /tmp when they exist", function()
            path_exists_map["/tmp/koreader/plugins/localsend.koplugin/certs"] = true
            path_exists_map["/tmp/koreader/plugins/localsend.koplugin/certs/server.key.pem"] = true
            path_exists_map["/tmp/koreader/plugins/localsend.koplugin/certs/server.crt"] = true

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            os_execute_calls = {}
            local result = instance:setupCertificates()

            assert.is_true(result, "Should return true when certs exist")

            local found_ln_key = false
            local found_ln_crt = false
            for _, cmd in ipairs(os_execute_calls) do
                if cmd:match("'ln' '%-sf'") then
                    if cmd:match("server%.key%.pem") then
                        found_ln_key = true
                    end
                    if cmd:match("server%.crt") then
                        found_ln_crt = true
                    end
                end
            end
            assert.is_true(found_ln_key, "Should symlink key file")
            assert.is_true(found_ln_crt, "Should symlink cert file")
        end)

        it("should return false when stored certs do not exist", function()
            path_exists_map["/tmp/koreader/plugins/localsend.koplugin/certs"] = true
            path_exists_map["/tmp/koreader/plugins/localsend.koplugin/certs/server.key.pem"] = false
            path_exists_map["/tmp/koreader/plugins/localsend.koplugin/certs/server.crt"] = false

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local result = instance:setupCertificates()

            assert.is_false(result, "Should return false when certs don't exist")
        end)

        it("should return false when only key exists", function()
            path_exists_map["/tmp/koreader/plugins/localsend.koplugin/certs"] = true
            path_exists_map["/tmp/koreader/plugins/localsend.koplugin/certs/server.key.pem"] = true
            path_exists_map["/tmp/koreader/plugins/localsend.koplugin/certs/server.crt"] = false

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local result = instance:setupCertificates()

            assert.is_false(result, "Should return false when only key exists")
        end)

        it("should return false when only cert exists", function()
            path_exists_map["/tmp/koreader/plugins/localsend.koplugin/certs"] = true
            path_exists_map["/tmp/koreader/plugins/localsend.koplugin/certs/server.key.pem"] = false
            path_exists_map["/tmp/koreader/plugins/localsend.koplugin/certs/server.crt"] = true

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local result = instance:setupCertificates()

            assert.is_false(result, "Should return false when only cert exists")
        end)
    end)

    describe("saveCertificates", function()
        it("should copy temp certs to storage when they exist and not already saved", function()
            path_exists_map["/tmp/server.key.pem"] = true
            path_exists_map["/tmp/server.crt"] = true
            path_exists_map["/tmp/koreader/plugins/localsend.koplugin/certs/server.key.pem"] = false

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            os_execute_calls = {}
            instance:saveCertificates()

            local found_cp_key = false
            local found_cp_crt = false
            for _, cmd in ipairs(os_execute_calls) do
                if cmd:match("^'cp'") then
                    if cmd:match("server%.key%.pem") then
                        found_cp_key = true
                    end
                    if cmd:match("server%.crt") then
                        found_cp_crt = true
                    end
                end
            end
            assert.is_true(found_cp_key, "Should copy key file")
            assert.is_true(found_cp_crt, "Should copy cert file")
        end)

        it("should not copy when certs already saved", function()
            path_exists_map["/tmp/server.key.pem"] = true
            path_exists_map["/tmp/server.crt"] = true
            path_exists_map["/tmp/koreader/plugins/localsend.koplugin/certs/server.key.pem"] = true

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            os_execute_calls = {}
            instance:saveCertificates()

            local found_cp = false
            for _, cmd in ipairs(os_execute_calls) do
                if cmd:match("^cp ") then
                    found_cp = true
                    break
                end
            end
            assert.is_false(found_cp, "Should not copy when already saved")
        end)

        it("should not copy when temp key doesn't exist", function()
            path_exists_map["/tmp/server.key.pem"] = false
            path_exists_map["/tmp/server.crt"] = true
            path_exists_map["/tmp/koreader/plugins/localsend.koplugin/certs/server.key.pem"] = false

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            os_execute_calls = {}
            instance:saveCertificates()

            local found_cp = false
            for _, cmd in ipairs(os_execute_calls) do
                if cmd:match("^cp ") then
                    found_cp = true
                    break
                end
            end
            assert.is_false(found_cp, "Should not copy when temp key doesn't exist")
        end)

        it("should not copy when temp cert doesn't exist", function()
            path_exists_map["/tmp/server.key.pem"] = true
            path_exists_map["/tmp/server.crt"] = false
            path_exists_map["/tmp/koreader/plugins/localsend.koplugin/certs/server.key.pem"] = false

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            os_execute_calls = {}
            instance:saveCertificates()

            local found_cp = false
            for _, cmd in ipairs(os_execute_calls) do
                if cmd:match("^cp ") then
                    found_cp = true
                    break
                end
            end
            assert.is_false(found_cp, "Should not copy when temp cert doesn't exist")
        end)
    end)

    describe("rotateCertificates", function()
        it("should remove stored certificates", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            os_execute_calls = {}
            instance:rotateCertificates()

            local found_rm_stored_key = false
            local found_rm_stored_crt = false
            for _, cmd in ipairs(os_execute_calls) do
                if cmd:match("'rm' '%-f'") then
                    if cmd:match("certs/server%.key%.pem") then
                        found_rm_stored_key = true
                    end
                    if cmd:match("certs/server%.crt") then
                        found_rm_stored_crt = true
                    end
                end
            end
            assert.is_true(found_rm_stored_key, "Should remove stored key")
            assert.is_true(found_rm_stored_crt, "Should remove stored cert")
        end)

        it("should remove temp certificates", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            os_execute_calls = {}
            instance:rotateCertificates()

            local found_rm_tmp_key = false
            local found_rm_tmp_crt = false
            for _, cmd in ipairs(os_execute_calls) do
                if cmd:match("'rm' '%-f'") then
                    if cmd:match("/tmp/server%.key%.pem") then
                        found_rm_tmp_key = true
                    end
                    if cmd:match("/tmp/server%.crt") then
                        found_rm_tmp_crt = true
                    end
                end
            end
            assert.is_true(found_rm_tmp_key, "Should remove temp key")
            assert.is_true(found_rm_tmp_crt, "Should remove temp cert")
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
