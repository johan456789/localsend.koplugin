require 'busted.runner'()

-- Tests for extension routing functionality

describe("Extension Routing", function()
    local LocalSend
    local saved_settings

    setup(function()
        -- Mock dependencies
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
            retrieveNetworkInfo = function() return "WiFi: 192.168.1.100" end,
        }
        package.loaded["dispatcher"] = { registerAction = function() end }
        package.loaded["ui/widget/infomessage"] = { new = function(self, o) return o end }
        package.loaded["ui/widget/notification"] = { new = function(self, o) return o end }
        package.loaded["ui/widget/inputdialog"] = { new = function(self, o) return o end }
        package.loaded["ui/widget/pathchooser"] = { new = function(self, o) return o end }
        package.loaded["ui/network/manager"] = {
            isOnline = function() return true end,
            runWhenOnline = function(self, callback) callback() end,
            runWhenConnected = function(self, callback) callback() end,
            isConnected = function() return true end,
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
            encode = function(t)
                -- Simple but functional JSON encoder
                if type(t) ~= "table" then return tostring(t) end
                local parts = {}
                for k, v in pairs(t) do
                    local val = type(v) == "string" and ('"' .. v .. '"') or tostring(v)
                    table.insert(parts, '"' .. k .. '":' .. val)
                end
                table.sort(parts) -- For deterministic output
                return "{" .. table.concat(parts, ",") .. "}"
            end,
            decode = function(s) return {} end,
        }
        package.loaded["localsend_utils"] = require("localsend_utils")

        saved_settings = {}
        _G.G_reader_settings = {
            readSetting = function(self, key) return saved_settings[key] end,
            saveSetting = function(self, key, value) saved_settings[key] = value end,
            isTrue = function(self, key) return saved_settings[key] == true end,
            nilOrTrue = function(self, key) return saved_settings[key] ~= false end,
            flipNilOrTrue = function(self, key) saved_settings[key] = not self:nilOrTrue(key) end,
            flipNilOrFalse = function(self, key) saved_settings[key] = not self:isTrue(key) end,
            _reset = function()
                for k in pairs(saved_settings) do saved_settings[k] = nil end
            end,
        }

        _G.dofile = function(path)
            if path:match("_meta%.lua$") then
                return { version = "v1.1.1" }
            end
            error("dofile not mocked for: " .. path)
        end
    end)

    before_each(function()
        G_reader_settings._reset()
        package.loaded["main"] = nil
    end)

    describe("addExtensionRoute", function()
        it("should lowercase extension", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance:addExtensionRoute("EPUB", "/books")

            assert.is_not_nil(instance.ext_dirs["epub"])
            assert.is_nil(instance.ext_dirs["EPUB"])
            assert.equal("/books", instance.ext_dirs["epub"])
        end)

        it("should auto-enable routing on first route", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.is_false(instance.routing_enabled)

            instance:addExtensionRoute("epub", "/books")

            assert.is_true(instance.routing_enabled)
        end)

        it("should persist routes to settings", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance:addExtensionRoute("epub", "/books")
            instance:addExtensionRoute("pdf", "/docs")

            local saved = saved_settings["LocalSend_ext_dirs"]
            assert.is_not_nil(saved)
            assert.equal("/books", saved["epub"])
            assert.equal("/docs", saved["pdf"])
        end)

        it("should overwrite existing route for same extension", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance:addExtensionRoute("epub", "/old")
            instance:addExtensionRoute("epub", "/new")

            assert.equal("/new", instance.ext_dirs["epub"])
        end)
    end)

    describe("removeExtensionRoute", function()
        it("should remove route", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance:addExtensionRoute("epub", "/books")
            instance:addExtensionRoute("pdf", "/docs")

            instance:removeExtensionRoute("epub")

            assert.is_nil(instance.ext_dirs["epub"])
            assert.equal("/docs", instance.ext_dirs["pdf"])
        end)

        it("should handle case-insensitive removal", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance:addExtensionRoute("epub", "/books")
            instance:removeExtensionRoute("EPUB")

            assert.is_nil(instance.ext_dirs["epub"])
        end)

        it("should not error when removing non-existent route", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            assert.has_no.errors(function()
                instance:removeExtensionRoute("nonexistent")
            end)
        end)
    end)

    describe("exportExtRouting", function()
        it("should return nil when routing disabled", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance.routing_enabled = false
            instance.ext_dirs = { epub = "/books" }

            local result = instance:exportExtRouting()
            assert.is_nil(result)
        end)

        it("should return nil when no routes configured", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance.routing_enabled = true
            instance.ext_dirs = {}

            local result = instance:exportExtRouting()
            assert.is_nil(result)
        end)

        it("should not include default when routing_accept_all is false", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance.routing_enabled = true
            instance.routing_accept_all = false
            instance.ext_dirs = { epub = "/books" }
            instance.save_dir = "/default"

            -- Mock io.open to capture what's written
            local written_content = nil
            local mock_file = {
                write = function(self, content) written_content = content end,
                close = function() end,
            }
            local original_io_open = io.open
            io.open = function(path, mode)
                if mode == "w" then return mock_file end
                return original_io_open(path, mode)
            end

            instance:exportExtRouting()

            io.open = original_io_open

            assert.is_not_nil(written_content)
            assert.is_nil(written_content:match('"default"'))
        end)

        it("should include default when routing_accept_all is true", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance.routing_enabled = true
            instance.routing_accept_all = true
            instance.ext_dirs = { epub = "/books" }
            instance.save_dir = "/default"

            local written_content = nil
            local mock_file = {
                write = function(self, content) written_content = content end,
                close = function() end,
            }
            local original_io_open = io.open
            io.open = function(path, mode)
                if mode == "w" then return mock_file end
                return original_io_open(path, mode)
            end

            instance:exportExtRouting()

            io.open = original_io_open

            assert.is_not_nil(written_content)
            assert.is_not_nil(written_content:match('"default"'))
            assert.is_not_nil(written_content:match('"/default"'))
        end)

        it("returns nil when io.open fails", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance.routing_enabled = true
            instance.ext_dirs = { epub = "/books" }

            local original_io_open = io.open
            io.open = function(path, mode)
                if path:match("ext_routing%.json") then
                    return nil  -- Simulate file open failure
                end
                return original_io_open(path, mode)
            end

            local result = instance:exportExtRouting()

            io.open = original_io_open

            assert.is_nil(result)
        end)

        it("returns nil when json.encode throws error", function()
            package.loaded["json"] = {
                encode = function(t)
                    error("JSON encoding error")
                end,
                decode = function(s) return {} end,
            }
            package.loaded["main"] = nil

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance.routing_enabled = true
            instance.ext_dirs = { epub = "/books" }

            local mock_file = {
                write = function(self, content)
                    -- This will trigger the pcall to catch the error
                    error("JSON error")
                end,
                close = function() end,
            }
            local original_io_open = io.open
            io.open = function(path, mode)
                if path:match("ext_routing%.json") and mode == "w" then
                    return mock_file
                end
                return original_io_open(path, mode)
            end

            local result = instance:exportExtRouting()

            io.open = original_io_open

            assert.is_nil(result)
        end)

        it("closes file even when write fails", function()
            package.loaded["main"] = nil
            package.loaded["json"] = {
                encode = function(t)
                    error("JSON encoding error")
                end,
                decode = function(s) return {} end,
            }

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            instance.routing_enabled = true
            instance.ext_dirs = { epub = "/books" }

            local close_called = false
            local mock_file = {
                write = function(self, content)
                    error("Write error")
                end,
                close = function()
                    close_called = true
                end,
            }
            local original_io_open = io.open
            io.open = function(path, mode)
                if path:match("ext_routing%.json") and mode == "w" then
                    return mock_file
                end
                return original_io_open(path, mode)
            end

            instance:exportExtRouting()

            io.open = original_io_open

            assert.is_true(close_called, "Should close file even on write failure")
        end)
    end)

    describe("Route action dialog", function()
        it("should show action dialog with Change directory button", function()
            -- Fix template function to properly substitute values
            package.loaded["ffi/util"] = {
                template = function(s, ...)
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
            package.loaded["ui/widget/buttondialog"] = {
                new = function(self, o) return o end,
            }
            local dialogs_shown = {}
            package.loaded["ui/network/manager"] = {
            isOnline = function() return true end,
            runWhenOnline = function(self, callback) callback() end,
            runWhenConnected = function(self, callback) callback() end,
            isConnected = function() return true end,
        }
        package.loaded["ui/uimanager"] = {
                show = function(self, dialog)
                    table.insert(dialogs_shown, dialog)
                end,
                close = function() end,
                scheduleIn = function() end,
            unschedule = function() end,
            preventStandby = function() end,
            allowStandby = function() end,
            getElapsedTimeSinceBoot = function() return { sec = 0, usec = 0 } end,
            }
        package.loaded["pluginshare"] = {}

            package.loaded["main"] = nil
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.ext_dirs = { epub = "/books", pdf = "/docs" }
            instance.routing_enabled = true

            local menu = instance:buildExtensionRoutingMenu({ updateItems = function() end })

            -- Find route item with callback (route items have ".ext → dir" format)
            local route_item = nil
            for _, item in ipairs(menu) do
                if item.callback and item.text and item.text:match("→") and item.text:match("^%.") then
                    route_item = item
                    break
                end
            end

            assert.is_not_nil(route_item, "Should have a route item with callback")
            route_item.callback({ updateItems = function() end })

            -- Should show ButtonDialog with buttons
            assert.is_true(#dialogs_shown > 0, "Should show action dialog")
            local dialog = dialogs_shown[1]
            assert.is_not_nil(dialog.buttons)

            -- Check for Change directory button
            local found_change = false
            for _, row in ipairs(dialog.buttons) do
                for _, btn in ipairs(row) do
                    if btn.text and btn.text:match("Change directory") then
                        found_change = true
                        break
                    end
                end
            end
            assert.is_true(found_change, "Should have 'Change directory' button")
        end)

        it("should show action dialog with Remove route button", function()
            package.loaded["ffi/util"] = {
                template = function(s, ...)
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
            package.loaded["ui/widget/buttondialog"] = {
                new = function(self, o) return o end,
            }
            local dialogs_shown = {}
            package.loaded["ui/network/manager"] = {
            isOnline = function() return true end,
            runWhenOnline = function(self, callback) callback() end,
            runWhenConnected = function(self, callback) callback() end,
            isConnected = function() return true end,
        }
        package.loaded["ui/uimanager"] = {
                show = function(self, dialog)
                    table.insert(dialogs_shown, dialog)
                end,
                close = function() end,
                scheduleIn = function() end,
            unschedule = function() end,
            preventStandby = function() end,
            allowStandby = function() end,
            getElapsedTimeSinceBoot = function() return { sec = 0, usec = 0 } end,
            }
        package.loaded["pluginshare"] = {}

            package.loaded["main"] = nil
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.ext_dirs = { epub = "/books" }
            instance.routing_enabled = true

            local menu = instance:buildExtensionRoutingMenu({ updateItems = function() end })

            -- Find route item with callback (route items have ".ext → dir" format)
            local route_item = nil
            for _, item in ipairs(menu) do
                if item.callback and item.text and item.text:match("→") and item.text:match("^%.") then
                    route_item = item
                    break
                end
            end

            route_item.callback({ updateItems = function() end })

            local dialog = dialogs_shown[1]
            local found_remove = false
            for _, row in ipairs(dialog.buttons) do
                for _, btn in ipairs(row) do
                    if btn.text and btn.text:match("Remove route") then
                        found_remove = true
                        break
                    end
                end
            end
            assert.is_true(found_remove, "Should have 'Remove route' button")
        end)

        it("Remove route button should remove the route", function()
            package.loaded["ffi/util"] = {
                template = function(s, ...)
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
            local notifications_shown = {}
            package.loaded["ui/widget/infomessage"] = {
                new = function(self, o)
                    table.insert(notifications_shown, o)
                    return o
                end,
            }
            package.loaded["ui/widget/buttondialog"] = {
                new = function(self, o) return o end,
            }
            local dialogs_shown = {}
            package.loaded["ui/network/manager"] = {
            isOnline = function() return true end,
            runWhenOnline = function(self, callback) callback() end,
            runWhenConnected = function(self, callback) callback() end,
            isConnected = function() return true end,
        }
        package.loaded["ui/uimanager"] = {
                show = function(self, dialog)
                    table.insert(dialogs_shown, dialog)
                end,
                close = function() end,
                scheduleIn = function() end,
            unschedule = function() end,
            preventStandby = function() end,
            allowStandby = function() end,
            getElapsedTimeSinceBoot = function() return { sec = 0, usec = 0 } end,
            }
        package.loaded["pluginshare"] = {}

            package.loaded["main"] = nil
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.ext_dirs = { epub = "/books", pdf = "/docs" }
            instance.routing_enabled = true

            local menu = instance:buildExtensionRoutingMenu({ updateItems = function() end })

            -- Find route item with callback (route items have ".ext → dir" format)
            local route_item = nil
            for _, item in ipairs(menu) do
                if item.callback and item.text and item.text:match("→") and item.text:match("^%.") then
                    route_item = item
                    break
                end
            end
            route_item.callback({ updateItems = function() end })

            -- Find and click Remove route button
            local dialog = dialogs_shown[1]
            local remove_button = nil
            for _, row in ipairs(dialog.buttons) do
                for _, btn in ipairs(row) do
                    if btn.text and btn.text:match("Remove route") then
                        remove_button = btn
                        break
                    end
                end
            end

            -- Count routes before
            local count_before = 0
            for _ in pairs(instance.ext_dirs) do count_before = count_before + 1 end

            remove_button.callback()

            -- Count routes after
            local count_after = 0
            for _ in pairs(instance.ext_dirs) do count_after = count_after + 1 end

            -- Should have one less route
            assert.equal(count_before - 1, count_after, "Should remove one route")

            -- Should show notification
            local found_notification = false
            for _, n in ipairs(notifications_shown) do
                if n.text and n.text:match("removed") then
                    found_notification = true
                    break
                end
            end
            assert.is_true(found_notification, "Should show removal notification")
        end)

        it("Change directory button should open path picker", function()
            package.loaded["ffi/util"] = {
                template = function(s, ...)
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
            package.loaded["ui/widget/buttondialog"] = {
                new = function(self, o) return o end,
            }
            package.loaded["ui/widget/pathchooser"] = {
                new = function(self, o) return o end,
            }
            local dialogs_shown = {}
            package.loaded["ui/network/manager"] = {
            isOnline = function() return true end,
            runWhenOnline = function(self, callback) callback() end,
            runWhenConnected = function(self, callback) callback() end,
            isConnected = function() return true end,
        }
        package.loaded["ui/uimanager"] = {
                show = function(self, dialog)
                    table.insert(dialogs_shown, dialog)
                end,
                close = function() end,
                scheduleIn = function() end,
            unschedule = function() end,
            preventStandby = function() end,
            allowStandby = function() end,
            getElapsedTimeSinceBoot = function() return { sec = 0, usec = 0 } end,
            }
        package.loaded["pluginshare"] = {}

            package.loaded["main"] = nil
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.ext_dirs = { epub = "/books" }
            instance.routing_enabled = true
            instance.save_dir = "/mnt/us/documents"

            local picker_called = false
            local picker_ext = nil
            instance.showExtensionDirPicker = function(self, ext, menu)
                picker_called = true
                picker_ext = ext
            end

            local menu = instance:buildExtensionRoutingMenu({ updateItems = function() end })

            -- Find route item with callback (route items have ".ext → dir" format)
            local route_item = nil
            for _, item in ipairs(menu) do
                if item.callback and item.text and item.text:match("→") and item.text:match("^%.") then
                    route_item = item
                    break
                end
            end
            route_item.callback({ updateItems = function() end })

            -- Find and click Change directory button
            local dialog = dialogs_shown[1]
            local change_button = nil
            for _, row in ipairs(dialog.buttons) do
                for _, btn in ipairs(row) do
                    if btn.text and btn.text:match("Change directory") then
                        change_button = btn
                        break
                    end
                end
            end

            change_button.callback()

            assert.is_true(picker_called, "Should call showExtensionDirPicker")
        end)
    end)
end)
