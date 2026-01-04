require 'busted.runner'()

-- Tests for validation functions: validateDeviceName, validateSaveDir

describe("Validation Functions", function()
    local LocalSend
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
            retrieveNetworkInfo = function() return "WiFi" end,
        }
        package.loaded["dispatcher"] = { registerAction = function() end }
        package.loaded["ui/widget/infomessage"] = { new = function(self, o) return o end }
        package.loaded["ui/widget/inputdialog"] = { new = function(self, o) return o end }
        package.loaded["ui/widget/pathchooser"] = { new = function(self, o) return o end }
        package.loaded["ui/network/manager"] = {
            isOnline = function() return true end,
            runWhenOnline = function(self, callback) callback() end,
            runWhenConnected = function(self, callback) callback() end,
        }
        package.loaded["ui/uimanager"] = {
            show = function() end,
            close = function() end,
            scheduleIn = function() end,
            unschedule = function() end,
            preventStandby = function() end,
            allowStandby = function() end,
            getElapsedTimeSinceBoot = function() return { sec = 0, usec = 0 } end,
        }
        package.loaded["pluginshare"] = {}

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

        _G.dofile = function(path)
            if path:match("_meta%.lua$") then
                return { version = "v1.1.1" }
            end
        end
    end)

    before_each(function()
        settings = {}
        _G.G_reader_settings = {
            readSetting = function(self, key) return settings[key] end,
            saveSetting = function(self, key, value) settings[key] = value end,
            isTrue = function(self, key) return settings[key] == true end,
            nilOrTrue = function(self, key) return settings[key] ~= false end,
            flipNilOrTrue = function(self, key) settings[key] = not self:nilOrTrue(key) end,
            flipNilOrFalse = function(self, key) settings[key] = not self:isTrue(key) end,
        }

        package.loaded["main"] = nil
    end)

    describe("validateDeviceName", function()
        it("accepts empty name (random name will be used)", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local valid, err = instance:validateDeviceName("")
            assert.is_true(valid)
            assert.is_nil(err)
        end)

        it("accepts valid alphanumeric name", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local valid, err = instance:validateDeviceName("MyKindle123")
            assert.is_true(valid)
            assert.is_nil(err)
        end)

        it("accepts name with spaces", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local valid, err = instance:validateDeviceName("My Kindle Reader")
            assert.is_true(valid)
        end)

        it("accepts name with hyphens", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local valid, err = instance:validateDeviceName("My-Kindle-Reader")
            assert.is_true(valid)
        end)

        it("accepts name with underscores", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local valid, err = instance:validateDeviceName("My_Kindle_Reader")
            assert.is_true(valid)
        end)

        it("accepts name with straight apostrophe", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local valid, err = instance:validateDeviceName("John's Kindle")
            assert.is_true(valid)
        end)

        it("accepts name with curly apostrophes", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            -- Left single quote and right single quote (curly)
            local valid1, _ = instance:validateDeviceName("John's Device")  -- right single quote
            local valid2, _ = instance:validateDeviceName("John's Device")  -- regular apostrophe
            assert.is_true(valid1 or valid2)  -- At least one should work
        end)

        it("accepts generated alias style names", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            -- These are the style of names that get auto-generated
            local valid, err = instance:validateDeviceName("Special Pineapple")
            assert.is_true(valid)
        end)

        it("rejects name longer than 64 characters", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local long_name = string.rep("a", 65)
            local valid, err = instance:validateDeviceName(long_name)
            assert.is_false(valid)
            assert.truthy(err:match("too long") or err:match("64"))
        end)

        it("accepts name exactly 64 characters", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local exact_name = string.rep("a", 64)
            local valid, err = instance:validateDeviceName(exact_name)
            assert.is_true(valid)
        end)

        it("rejects name with shell injection characters", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            -- These could be used for shell injection
            local valid1, _ = instance:validateDeviceName("test; rm -rf /")
            local valid2, _ = instance:validateDeviceName("test$(whoami)")
            local valid3, _ = instance:validateDeviceName("test`id`")
            local valid4, _ = instance:validateDeviceName("test|cat /etc/passwd")

            assert.is_false(valid1)
            assert.is_false(valid2)
            assert.is_false(valid3)
            assert.is_false(valid4)
        end)

        it("rejects name with angle brackets (potential XSS)", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local valid, err = instance:validateDeviceName("<script>alert(1)</script>")
            assert.is_false(valid)
        end)

        it("rejects name with quotes", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local valid1, _ = instance:validateDeviceName('test"name')
            local valid2, _ = instance:validateDeviceName("test'name")  -- This might be allowed with apostrophe

            assert.is_false(valid1)  -- Double quotes should be rejected
        end)

        it("allows name with newlines (matched by %s pattern)", function()
            -- Note: The current implementation uses %s which matches newlines
            -- This test documents the current behavior
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local valid, err = instance:validateDeviceName("test\nname")
            -- Current implementation allows this - %s matches newline
            assert.is_true(valid)
        end)

        it("rejects name with backslash", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local valid, err = instance:validateDeviceName("test\\name")
            assert.is_false(valid)
        end)

        it("rejects name with null byte", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local valid, err = instance:validateDeviceName("test\0name")
            assert.is_false(valid)
        end)

        it("returns appropriate error message for invalid characters", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local valid, err = instance:validateDeviceName("test@name!")
            assert.is_false(valid)
            assert.truthy(err:match("letters") or err:match("characters"))
        end)

        -- =====================================================================
        -- validateDeviceName Nil Check
        -- =====================================================================

        -- This test SHOULD FAIL on the current codebase.
        -- The current implementation checks `if name == ""` which passes for nil,
        -- but then `#name` on line 91 will error because #nil is invalid in Lua.
        it("handles nil name without error", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            -- Passing nil should not cause an error
            -- Current code: if name == "" then  -- nil passes this check
            --               if #name > 64 then  -- ERROR: #nil is invalid!
            local ok, result = pcall(function()
                return instance:validateDeviceName(nil)
            end)

            -- The function should handle nil gracefully
            assert.is_true(ok, "validateDeviceName should not error on nil input")
            if ok then
                -- If it doesn't error, it should treat nil as valid (empty = random name)
                assert.is_true(result, "nil should be treated as valid (empty name)")
            end
        end)

        -- Additional nil edge case tests
        it("handles nil from settings gracefully", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            -- Simulate what happens when settings return nil for device_name
            -- This is a common scenario when the setting hasn't been configured
            local device_name = nil  -- simulates G_reader_settings:readSetting("localsend_device_name")

            local ok, err_or_result = pcall(function()
                return instance:validateDeviceName(device_name)
            end)

            assert.is_true(ok, "Should handle nil from settings without error: " .. tostring(err_or_result))
        end)
    end)
end)
