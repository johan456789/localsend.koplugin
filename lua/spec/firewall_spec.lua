require 'busted.runner'()

-- Tests for iptables firewall management functions

describe("Firewall Management", function()
    local LocalSend
    local iptables_rules
    local os_execute_calls

    setup(function()
        package.loaded["ffi/util"] = {
            template = function(s, ...) return s end,
            usleep = function() end,
            sleep = function() end,
        }
        package.loaded["datastorage"] = {
            getFullDataDir = function() return "/tmp/koreader" end,
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
                if path == "/tmp/koreader/plugins/localsend.koplugin" then return true end
                if path == "/tmp/koreader/plugins/localsend.koplugin/localsend" then return true end
                return false
            end,
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
        iptables_rules = {}
        os_execute_calls = {}

        -- Simulate iptables behavior
        _G.os.execute = function(cmd)
            table.insert(os_execute_calls, cmd)

            -- iptables -C (check): return 0 if rule exists, 1 if not
            if cmd:match("iptables %-C") then
                local rule = cmd:match("iptables %-C (.+) 2>/dev/null")
                if rule and iptables_rules[rule] then
                    return 0
                end
                return 1
            end

            -- iptables -A (add): add rule
            if cmd:match("iptables %-A") then
                local rule = cmd:match("iptables %-A (.+)")
                if rule then
                    iptables_rules[rule] = true
                end
                return 0
            end

            -- iptables -D (delete): remove rule
            if cmd:match("iptables %-D") then
                local rule = cmd:match("iptables %-D (.+)")
                -- Handle 2>/dev/null suffix
                rule = rule and rule:gsub(" 2>/dev/null$", "")
                if rule then
                    iptables_rules[rule] = nil
                end
                return 0
            end

            return 0
        end

        package.loaded["main"] = nil
        -- Need to reload device to mock isKindle
        package.loaded["device"] = nil
    end)

    describe("on Kindle devices", function()
        before_each(function()
            package.loaded["device"] = {
                isKindle = function() return true end,
                retrieveNetworkInfo = function() return "WiFi" end,
            }
        end)

        describe("openFirewall", function()
            it("adds TCP rules for the configured port", function()
                LocalSend = require("main")
                local instance = LocalSend:new{
                    ui = { menu = { registerToMainMenu = function() end } }
                }
                instance.port = "53317"

                instance:openFirewall()

                -- Should have added INPUT and OUTPUT TCP rules
                assert.is_not_nil(iptables_rules["INPUT -p tcp --dport 53317 -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT"])
                assert.is_not_nil(iptables_rules["OUTPUT -p tcp --sport 53317 -m conntrack --ctstate ESTABLISHED -j ACCEPT"])
            end)

            it("adds UDP rules for discovery", function()
                LocalSend = require("main")
                local instance = LocalSend:new{
                    ui = { menu = { registerToMainMenu = function() end } }
                }
                instance.port = "53317"

                instance:openFirewall()

                assert.is_not_nil(iptables_rules["INPUT -p udp --dport 53317 -j ACCEPT"])
                assert.is_not_nil(iptables_rules["OUTPUT -p udp --sport 53317 -j ACCEPT"])
            end)

            it("adds WebRTC UDP port range when enabled", function()
                LocalSend = require("main")
                local instance = LocalSend:new{
                    ui = { menu = { registerToMainMenu = function() end } }
                }
                instance.port = "53317"
                instance.use_webrtc = true

                instance:openFirewall()

                assert.is_not_nil(iptables_rules["INPUT -p udp --dport 50000:50100 -j ACCEPT"])
                assert.is_not_nil(iptables_rules["OUTPUT -p udp --sport 50000:50100 -j ACCEPT"])
            end)

            it("does not add WebRTC rules when disabled", function()
                LocalSend = require("main")
                local instance = LocalSend:new{
                    ui = { menu = { registerToMainMenu = function() end } }
                }
                instance.port = "53317"
                instance.use_webrtc = false

                instance:openFirewall()

                assert.is_nil(iptables_rules["INPUT -p udp --dport 50000:50100 -j ACCEPT"])
                assert.is_nil(iptables_rules["OUTPUT -p udp --sport 50000:50100 -j ACCEPT"])
            end)

            it("does not add duplicate rules (idempotent)", function()
                LocalSend = require("main")
                local instance = LocalSend:new{
                    ui = { menu = { registerToMainMenu = function() end } }
                }
                instance.port = "53317"

                -- Pre-add a rule
                iptables_rules["INPUT -p tcp --dport 53317 -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT"] = true

                local add_count = 0
                local original_execute = os.execute
                _G.os.execute = function(cmd)
                    if cmd:match("iptables %-A INPUT %-p tcp .* 53317") then
                        add_count = add_count + 1
                    end
                    return original_execute(cmd)
                end

                instance:openFirewall()

                -- Should not have tried to add the rule again (check should have found it)
                assert.equal(0, add_count, "Should not add duplicate rule")
            end)

            it("checks rule existence (-C) before adding (-A)", function()
                LocalSend = require("main")
                local instance = LocalSend:new{
                    ui = { menu = { registerToMainMenu = function() end } }
                }
                instance.port = "53317"

                local command_order = {}
                local original_execute = os.execute
                _G.os.execute = function(cmd)
                    if cmd:match("iptables %-C") then
                        table.insert(command_order, "check")
                    elseif cmd:match("iptables %-A") then
                        table.insert(command_order, "add")
                    end
                    return original_execute(cmd)
                end

                instance:openFirewall()

                -- Find first check and first add
                local first_check_idx = nil
                local first_add_idx = nil
                for i, cmd_type in ipairs(command_order) do
                    if cmd_type == "check" and not first_check_idx then
                        first_check_idx = i
                    elseif cmd_type == "add" and not first_add_idx then
                        first_add_idx = i
                    end
                end

                assert.is_not_nil(first_check_idx, "Should have called iptables -C")
                assert.is_not_nil(first_add_idx, "Should have called iptables -A")
                assert.is_true(first_check_idx < first_add_idx, "Check (-C) should come before add (-A)")
            end)

            it("rejects invalid port", function()
                LocalSend = require("main")
                local instance = LocalSend:new{
                    ui = { menu = { registerToMainMenu = function() end } }
                }
                instance.port = "invalid"

                -- Clear calls
                os_execute_calls = {}

                instance:openFirewall()

                -- Should not have called any iptables commands
                local iptables_calls = 0
                for _, cmd in ipairs(os_execute_calls) do
                    if cmd:match("iptables") then
                        iptables_calls = iptables_calls + 1
                    end
                end
                assert.equal(0, iptables_calls, "Should not call iptables with invalid port")
            end)
        end)

        describe("closeFirewall", function()
            it("removes TCP rules", function()
                -- Pre-add rules
                iptables_rules["INPUT -p tcp --dport 53317 -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT"] = true
                iptables_rules["OUTPUT -p tcp --sport 53317 -m conntrack --ctstate ESTABLISHED -j ACCEPT"] = true

                LocalSend = require("main")
                local instance = LocalSend:new{
                    ui = { menu = { registerToMainMenu = function() end } }
                }
                instance.port = "53317"

                instance:closeFirewall()

                -- Rules should be gone (our mock removes them)
                -- Check that delete commands were issued
                local found_delete = false
                for _, cmd in ipairs(os_execute_calls) do
                    if cmd:match("iptables %-D") then
                        found_delete = true
                        break
                    end
                end
                assert.is_true(found_delete, "Should issue delete commands")
            end)

            it("removes UDP rules", function()
                iptables_rules["INPUT -p udp --dport 53317 -j ACCEPT"] = true
                iptables_rules["OUTPUT -p udp --sport 53317 -j ACCEPT"] = true

                LocalSend = require("main")
                local instance = LocalSend:new{
                    ui = { menu = { registerToMainMenu = function() end } }
                }
                instance.port = "53317"

                instance:closeFirewall()

                local udp_deletes = 0
                for _, cmd in ipairs(os_execute_calls) do
                    if cmd:match("iptables %-D .* %-p udp .* 53317") then
                        udp_deletes = udp_deletes + 1
                    end
                end
                assert.equal(2, udp_deletes, "Should delete both UDP rules")
            end)

            it("attempts to remove WebRTC rules (ignoring errors)", function()
                LocalSend = require("main")
                local instance = LocalSend:new{
                    ui = { menu = { registerToMainMenu = function() end } }
                }
                instance.port = "53317"

                instance:closeFirewall()

                -- Should attempt to remove WebRTC rules with 2>/dev/null
                local found_webrtc_cleanup = false
                for _, cmd in ipairs(os_execute_calls) do
                    if cmd:match("50000:50100") and cmd:match("2>/dev/null") then
                        found_webrtc_cleanup = true
                        break
                    end
                end
                assert.is_true(found_webrtc_cleanup, "Should attempt WebRTC cleanup")
            end)

            it("rejects invalid port", function()
                LocalSend = require("main")
                local instance = LocalSend:new{
                    ui = { menu = { registerToMainMenu = function() end } }
                }
                instance.port = "99999" -- Out of range

                os_execute_calls = {}

                instance:closeFirewall()

                local iptables_calls = 0
                for _, cmd in ipairs(os_execute_calls) do
                    if cmd:match("iptables") then
                        iptables_calls = iptables_calls + 1
                    end
                end
                assert.equal(0, iptables_calls, "Should not call iptables with invalid port")
            end)
        end)
    end)

    describe("on non-Kindle devices", function()
        before_each(function()
            package.loaded["device"] = {
                isKindle = function() return false end,
                retrieveNetworkInfo = function() return "WiFi" end,
            }
        end)

        it("openFirewall does nothing", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.port = "53317"

            os_execute_calls = {}

            instance:openFirewall()

            local iptables_calls = 0
            for _, cmd in ipairs(os_execute_calls) do
                if cmd:match("iptables") then
                    iptables_calls = iptables_calls + 1
                end
            end
            assert.equal(0, iptables_calls, "Should not call iptables on non-Kindle")
        end)

        it("closeFirewall does nothing", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.port = "53317"

            os_execute_calls = {}

            instance:closeFirewall()

            local iptables_calls = 0
            for _, cmd in ipairs(os_execute_calls) do
                if cmd:match("iptables") then
                    iptables_calls = iptables_calls + 1
                end
            end
            assert.equal(0, iptables_calls, "Should not call iptables on non-Kindle")
        end)
    end)
end)
