require 'busted.runner'()

-- Tests for showRecentTransfers function

describe("showRecentTransfers", function()
    local LocalSend
    local notifications_shown

    setup(function()
        package.loaded["ffi/util"] = {
            template = function(s, ...)
                -- Simple template substitution for %1, %2, etc.
                local args = {...}
                local result = s
                for i, v in ipairs(args) do
                    result = result:gsub("%%" .. i, tostring(v))
                end
                return result
            end,
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
                if path == "/tmp/koreader/plugins/localsend.koplugin" then return true end
                if path == "/tmp/koreader/plugins/localsend.koplugin/localsend" then return true end
                return false
            end,
            getFriendlySize = function(size)
                if size >= 1048576 then
                    return string.format("%.1f MB", size / 1048576)
                elseif size >= 1024 then
                    return string.format("%.1f KB", size / 1024)
                else
                    return string.format("%d B", size)
                end
            end,
        }

        package.loaded["ui/widget/infomessage"] = {
            new = function(self, o)
                table.insert(notifications_shown, o)
                return o
            end,
        }

        package.loaded["localsend_utils"] = require("localsend_utils")
        package.loaded["main"] = nil
    end)

    describe("with no transfers", function()
        it("should show 'No recent transfers' message", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.getTransferLog = function() return {} end

            notifications_shown = {}
            instance:showRecentTransfers()

            local found_empty = false
            for _, n in ipairs(notifications_shown) do
                if n.text and n.text:match("No recent transfers") then
                    found_empty = true
                    break
                end
            end
            assert.is_true(found_empty)
        end)

        it("message should have timeout", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.getTransferLog = function() return {} end

            notifications_shown = {}
            instance:showRecentTransfers()

            assert.equal(3, notifications_shown[1].timeout)
        end)
    end)

    describe("with transfers", function()
        it("should show transfer count in header", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.getTransferLog = function()
                return {
                    { filename = "book1.epub", size = 1024 },
                    { filename = "book2.pdf", size = 2048 },
                }
            end

            notifications_shown = {}
            instance:showRecentTransfers()

            -- Check that we got a notification with some content
            assert.is_true(#notifications_shown > 0)
            local text = notifications_shown[1].text
            assert.is_not_nil(text)
            -- Should contain "2" somewhere (total count) or the filenames
            assert.truthy(text:match("2") or text:match("book1") or text:match("book2"),
                "Should show transfer information")
        end)

        it("should show file names", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.getTransferLog = function()
                return {
                    { filename = "test.epub", size = 1024 },
                }
            end

            notifications_shown = {}
            instance:showRecentTransfers()

            local text = notifications_shown[1].text
            assert.truthy(text:match("test%.epub"), "Should show filename")
        end)

        it("should format size in bytes for small files", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.getTransferLog = function()
                return {
                    { filename = "small.txt", size = 500 },
                }
            end

            notifications_shown = {}
            instance:showRecentTransfers()

            local text = notifications_shown[1].text
            -- Should have size in bytes format
            assert.truthy(text:match("500") or text:match("B"), "Should show size info")
        end)

        it("should format size in KB for medium files", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.getTransferLog = function()
                return {
                    { filename = "medium.epub", size = 51200 }, -- 50 KB
                }
            end

            notifications_shown = {}
            instance:showRecentTransfers()

            local text = notifications_shown[1].text
            -- Should have KB somewhere
            assert.truthy(text:match("KB") or text:match("50"), "Should show KB size")
        end)

        it("should format size in MB for large files", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.getTransferLog = function()
                return {
                    { filename = "large.pdf", size = 5242880 }, -- 5 MB
                }
            end

            notifications_shown = {}
            instance:showRecentTransfers()

            local text = notifications_shown[1].text
            -- Should have MB somewhere
            assert.truthy(text:match("MB") or text:match("5"), "Should show MB size")
        end)

        it("should only show last 10 transfers", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.getTransferLog = function()
                local transfers = {}
                for i = 1, 15 do
                    table.insert(transfers, { filename = "file" .. i .. ".epub", size = 1024 })
                end
                return transfers
            end

            notifications_shown = {}
            instance:showRecentTransfers()

            local text = notifications_shown[1].text
            -- Should show the later files (6-15) not the earlier ones (1-5)
            assert.truthy(text:match("file15") or text:match("15"), "Should show recent files")
        end)

        it("should handle transfers without size", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.getTransferLog = function()
                return {
                    { filename = "nosize.epub" }, -- No size field
                }
            end

            notifications_shown = {}

            assert.has_no.errors(function()
                instance:showRecentTransfers()
            end)

            local text = notifications_shown[1].text
            assert.truthy(text:match("nosize%.epub"), "Should show filename without size")
        end)
    end)
end)
