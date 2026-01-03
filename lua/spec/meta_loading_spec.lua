require 'busted.runner'()

-- Tests for Issue #4: Unprotected dofile crashes plugin when _meta.lua is missing or corrupted
-- EXPECTED TO FAIL: Without the fix, loading main.lua when _meta.lua is missing will throw an error.
-- After fix: Should gracefully handle missing/corrupted _meta.lua using pcall.

describe("_meta.lua loading (Issue #4)", function()
    local original_dofile

    setup(function()
        -- Save original dofile
        original_dofile = _G.dofile

        -- Mock required modules
        package.loaded["ffi/util"] = {
            template = function(s, ...) return s end,
            usleep = function() end,
            isSubProcessDone = function() return true end,
            terminateSubProcess = function() end,
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
        package.loaded["ui/widget/infomessage"] = { new = function(self, o) return o end }
        package.loaded["ui/widget/inputdialog"] = { new = function(self, o) return o end }
        package.loaded["ui/widget/pathchooser"] = { new = function(self, o) return o end }
        package.loaded["ui/network/manager"] = { isOnline = function() return true end }
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
            warn = function(...) end,
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

        _G.G_reader_settings = {
            readSetting = function(self, key) return nil end,
            saveSetting = function(self, key, value) end,
            isTrue = function(self, key) return false end,
            nilOrTrue = function(self, key) return true end,
            flipNilOrTrue = function(self, key) end,
            flipNilOrFalse = function(self, key) end,
        }
    end)

    teardown(function()
        -- Restore original dofile
        _G.dofile = original_dofile
    end)

    before_each(function()
        -- Clear cached module
        package.loaded["main"] = nil
        package.loaded["localsend_utils"] = require("localsend_utils")
    end)

    describe("when _meta.lua is missing", function()
        -- After fix: pcall catches error and uses fallback values
        it("should gracefully handle missing _meta.lua file", function()
            -- Make dofile throw an error (simulating missing file)
            _G.dofile = function(path)
                if path:match("_meta%.lua$") then
                    error("cannot open " .. path .. ": No such file or directory")
                end
            end

            -- With the pcall fix, this should load successfully
            local ok, result = pcall(function()
                return require("main")
            end)

            -- After fix: ok should be true (plugin loads gracefully)
            assert.is_true(ok, "Plugin should load gracefully when _meta.lua is missing")
        end)
    end)

    describe("when _meta.lua is corrupted", function()
        -- After fix: pcall catches error and uses fallback values
        it("should gracefully handle corrupted _meta.lua file", function()
            -- Make dofile throw a syntax error (simulating corrupted file)
            _G.dofile = function(path)
                if path:match("_meta%.lua$") then
                    error("syntax error in " .. path)
                end
            end

            local ok, result = pcall(function()
                return require("main")
            end)

            -- After fix: ok should be true (plugin loads gracefully)
            assert.is_true(ok, "Plugin should load gracefully when _meta.lua has syntax error")
        end)
    end)

    describe("when _meta.lua returns nil", function()
        -- After fix: type check handles nil return value
        it("should gracefully handle when _meta.lua returns nil", function()
            _G.dofile = function(path)
                if path:match("_meta%.lua$") then
                    return nil  -- File exists but returns nothing
                end
            end

            local ok, result = pcall(function()
                return require("main")
            end)

            -- After fix: ok should be true (plugin loads gracefully with fallback)
            assert.is_true(ok, "Plugin should load gracefully when _meta.lua returns nil")
        end)
    end)

    describe("when _meta.lua is valid", function()
        -- This should always pass - normal operation
        it("should load version from valid _meta.lua", function()
            _G.dofile = function(path)
                if path:match("_meta%.lua$") then
                    return { version = "v1.2.3", name = "LocalSend" }
                end
            end

            local ok, result = pcall(function()
                return require("main")
            end)

            assert.is_true(ok)
        end)
    end)
end)
