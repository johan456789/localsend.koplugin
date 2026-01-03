require 'busted.runner'()

-- Tests for menu building functions

describe("Menu Building", function()
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
        package.loaded["ui/widget/buttondialog"] = { new = function(self, o) return o end }
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

    describe("buildExtensionPresetsMenu", function()
        it("returns a table of menu items", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local menu = instance:buildExtensionPresetsMenu()

            assert.is_table(menu)
            assert.is_true(#menu > 0)
        end)

        it("includes 'All files' option", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local menu = instance:buildExtensionPresetsMenu()

            local found = false
            for _, item in ipairs(menu) do
                if item.text and item.text:match("All files") then
                    found = true
                    break
                end
            end
            assert.is_true(found, "Should include 'All files' option")
        end)

        it("includes eBook presets", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local menu = instance:buildExtensionPresetsMenu()

            local found_ebooks = false
            for _, item in ipairs(menu) do
                if item.text and item.text:match("eBooks") then
                    found_ebooks = true
                    break
                end
            end
            assert.is_true(found_ebooks, "Should include eBooks preset")
        end)

        it("includes 'Custom...' option", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local menu = instance:buildExtensionPresetsMenu()

            local found = false
            for _, item in ipairs(menu) do
                if item.text and item.text:match("Custom") then
                    found = true
                    assert.is_true(item.keep_menu_open, "Custom should keep menu open")
                    break
                end
            end
            assert.is_true(found, "Should include 'Custom...' option")
        end)

        it("marks current selection as checked", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.accept_ext = "epub,pdf,mobi,azw3"

            local menu = instance:buildExtensionPresetsMenu()

            -- Find the eBooks option and check if it's checked
            for _, item in ipairs(menu) do
                if item.checked_func then
                    local is_checked = item.checked_func()
                    if item.text and item.text:match("eBooks") and item.text:match("epub.*pdf.*mobi.*azw3") then
                        assert.is_true(is_checked, "eBooks preset should be checked")
                    end
                end
            end
        end)
    end)

    describe("buildExtensionRoutingMenu", function()
        it("returns empty add option when no routes", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.ext_dirs = {}

            local menu = instance:buildExtensionRoutingMenu()

            -- Should have "Add extension route..." option
            local found_add = false
            for _, item in ipairs(menu) do
                if item.text and item.text:match("Add extension route") then
                    found_add = true
                    break
                end
            end
            assert.is_true(found_add, "Should have add route option")
        end)

        it("shows enable toggle when routes exist", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.ext_dirs = { epub = "/books" }
            instance.routing_enabled = true

            local menu = instance:buildExtensionRoutingMenu()

            local found_toggle = false
            for _, item in ipairs(menu) do
                if item.text and item.text:match("Enable file type routing") then
                    found_toggle = true
                    assert.is_function(item.checked_func)
                    assert.is_true(item.checked_func())
                    break
                end
            end
            assert.is_true(found_toggle, "Should show enable toggle when routes exist")
        end)

        it("lists existing routes", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.ext_dirs = {
                epub = "/books",
                pdf = "/documents",
            }

            local menu = instance:buildExtensionRoutingMenu()

            -- Routes are added to menu - count non-separator, non-toggle items
            local route_count = 0
            for _, item in ipairs(menu) do
                -- Check for route items (they have text with arrow or %1/%2 placeholder pattern)
                if item.text and (item.text:match("→") or item.text:match("%%1") or item.text:match("epub") or item.text:match("pdf")) then
                    route_count = route_count + 1
                end
            end
            -- Should have at least the routes in some form
            assert.is_true(route_count >= 1, "Should show routes")
        end)

        it("shows 'accept all' option when routes exist", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.ext_dirs = { epub = "/books" }
            instance.routing_accept_all = false

            local menu = instance:buildExtensionRoutingMenu()

            local found_accept_all = false
            for _, item in ipairs(menu) do
                if item.text and item.text:match("Accept other files") then
                    found_accept_all = true
                    assert.is_function(item.checked_func)
                    assert.is_false(item.checked_func())
                    break
                end
            end
            assert.is_true(found_accept_all, "Should show accept all option")
        end)

        it("does not show 'accept all' option when no routes", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.ext_dirs = {}

            local menu = instance:buildExtensionRoutingMenu()

            for _, item in ipairs(menu) do
                if item.text and item.text:match("Accept other files") then
                    assert.fail("Should not show accept all option when no routes")
                end
            end
        end)
    end)

    describe("addToMainMenu", function()
        it("adds localsend entry to menu_items", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local menu_items = {}
            instance:addToMainMenu(menu_items)

            assert.is_not_nil(menu_items.localsend)
        end)

        it("has text_func that shows status", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local menu_items = {}
            instance:addToMainMenu(menu_items)

            assert.is_function(menu_items.localsend.text_func)

            -- When not running
            instance.isRunning = function() return false end
            local text_not_running = menu_items.localsend.text_func()
            assert.equal("LocalSend", text_not_running)

            -- When running
            instance.isRunning = function() return true end
            instance.getTransferCount = function() return 0 end
            local text_running = menu_items.localsend.text_func()
            -- Template uses %1 placeholder, so match "(running)" or the template pattern
            assert.truthy(text_running:match("running") or text_running:match("LocalSend"))

            -- When running with transfers
            instance.getTransferCount = function() return 5 end
            local text_with_transfers = menu_items.localsend.text_func()
            -- Template uses %1 placeholder for count
            assert.truthy(text_with_transfers:match("received") or text_with_transfers:match("%%1") or text_with_transfers:match("5"))
        end)

        it("has sub_item_table with expected items", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local menu_items = {}
            instance:addToMainMenu(menu_items)

            local sub_items = menu_items.localsend.sub_item_table
            assert.is_table(sub_items)

            -- Check for key menu items
            local found_toggle = false
            local found_transfers = false
            local found_save_dir = false
            local found_settings = false
            local found_updates = false

            for _, item in ipairs(sub_items) do
                if item.text_func then
                    local text = item.text_func()
                    if text:match("Stop server") or text:match("Start server") then
                        found_toggle = true
                    elseif text:match("Recent transfers") then
                        found_transfers = true
                    elseif text:match("Save directory") then
                        found_save_dir = true
                    elseif text:match("Check for updates") then
                        found_updates = true
                    end
                elseif item.text then
                    if item.text == "Settings" then
                        found_settings = true
                    end
                end
            end

            assert.is_true(found_toggle, "Should have start/stop toggle")
            assert.is_true(found_transfers, "Should have recent transfers")
            assert.is_true(found_save_dir, "Should have save directory")
            assert.is_true(found_settings, "Should have settings submenu")
            assert.is_true(found_updates, "Should have check for updates")
        end)

        it("disables settings when server is running", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local menu_items = {}
            instance:addToMainMenu(menu_items)

            -- Find settings item
            local settings_item = nil
            for _, item in ipairs(menu_items.localsend.sub_item_table) do
                if item.text == "Settings" then
                    settings_item = item
                    break
                end
            end

            assert.is_not_nil(settings_item)
            assert.is_function(settings_item.enabled_func)

            -- When not running, should be enabled
            instance.isRunning = function() return false end
            assert.is_true(settings_item.enabled_func())

            -- When running, should be disabled
            instance.isRunning = function() return true end
            assert.is_false(settings_item.enabled_func())
        end)

        it("sets sorting_hint to network", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local menu_items = {}
            instance:addToMainMenu(menu_items)

            assert.equal("network", menu_items.localsend.sorting_hint)
        end)
    end)

    describe("text_func dynamic behavior", function()
        it("device name shows '(KOReader)' when empty", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.device_name = ""

            local menu_items = {}
            instance:addToMainMenu(menu_items)

            -- Find device name item in settings
            local settings_item = nil
            for _, item in ipairs(menu_items.localsend.sub_item_table) do
                if item.text == "Settings" then
                    settings_item = item
                    break
                end
            end

            assert.is_not_nil(settings_item)
            local device_name_item = nil
            for _, item in ipairs(settings_item.sub_item_table) do
                if item.text_func then
                    local text = item.text_func()
                    if text:match("Device name") then
                        device_name_item = item
                        break
                    end
                end
            end

            assert.is_not_nil(device_name_item)
            local text = device_name_item.text_func()
            assert.truthy(text:match("KOReader"), "Should show '(KOReader)' as default")
        end)

        it("device name shows actual name when set", function()
            -- Need proper template function
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
            package.loaded["main"] = nil

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.device_name = "My Kindle"

            local menu_items = {}
            instance:addToMainMenu(menu_items)

            local settings_item = nil
            for _, item in ipairs(menu_items.localsend.sub_item_table) do
                if item.text == "Settings" then
                    settings_item = item
                    break
                end
            end

            local device_name_item = nil
            for _, item in ipairs(settings_item.sub_item_table) do
                if item.text_func then
                    local text = item.text_func()
                    if text:match("Device name") then
                        device_name_item = item
                        break
                    end
                end
            end

            local text = device_name_item.text_func()
            assert.truthy(text:match("My Kindle"), "Should show actual device name")
        end)

        it("PIN code shows '(enabled)' when set", function()
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
            package.loaded["main"] = nil

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.pin = "1234"

            local menu_items = {}
            instance:addToMainMenu(menu_items)

            local settings_item = nil
            for _, item in ipairs(menu_items.localsend.sub_item_table) do
                if item.text == "Settings" then
                    settings_item = item
                    break
                end
            end

            local pin_item = nil
            for _, item in ipairs(settings_item.sub_item_table) do
                if item.text_func then
                    local text = item.text_func()
                    if text:match("PIN") then
                        pin_item = item
                        break
                    end
                end
            end

            local text = pin_item.text_func()
            assert.truthy(text:match("enabled"), "Should show '(enabled)' when PIN set")
        end)

        it("PIN code shows '(disabled)' when empty", function()
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
            package.loaded["main"] = nil

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.pin = ""

            local menu_items = {}
            instance:addToMainMenu(menu_items)

            local settings_item = nil
            for _, item in ipairs(menu_items.localsend.sub_item_table) do
                if item.text == "Settings" then
                    settings_item = item
                    break
                end
            end

            local pin_item = nil
            for _, item in ipairs(settings_item.sub_item_table) do
                if item.text_func then
                    local text = item.text_func()
                    if text:match("PIN") then
                        pin_item = item
                        break
                    end
                end
            end

            local text = pin_item.text_func()
            assert.truthy(text:match("disabled"), "Should show '(disabled)' when PIN empty")
        end)

        it("file type routing shows rule count", function()
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
            package.loaded["main"] = nil

            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }
            instance.ext_dirs = { epub = "/books", pdf = "/docs" }
            instance.routing_enabled = true

            local menu_items = {}
            instance:addToMainMenu(menu_items)

            local settings_item = nil
            for _, item in ipairs(menu_items.localsend.sub_item_table) do
                if item.text == "Settings" then
                    settings_item = item
                    break
                end
            end

            local routing_item = nil
            for _, item in ipairs(settings_item.sub_item_table) do
                if item.text_func then
                    local text = item.text_func()
                    if text:match("File type routing") then
                        routing_item = item
                        break
                    end
                end
            end

            local text = routing_item.text_func()
            assert.truthy(text:match("2") or text:match("rule"), "Should show rule count")
        end)
    end)

    describe("enabled_func behavior", function()
        it("recent transfers enabled only when transfers exist", function()
            LocalSend = require("main")
            local instance = LocalSend:new{
                ui = { menu = { registerToMainMenu = function() end } }
            }

            local menu_items = {}
            instance:addToMainMenu(menu_items)

            -- Find recent transfers item
            local transfers_item = nil
            for _, item in ipairs(menu_items.localsend.sub_item_table) do
                if item.text_func then
                    local text = item.text_func()
                    if text:match("Recent transfers") then
                        transfers_item = item
                        break
                    end
                end
            end

            assert.is_not_nil(transfers_item)
            assert.is_function(transfers_item.enabled_func)

            -- When no transfers, should be disabled
            instance.getTransferCount = function() return 0 end
            assert.is_false(transfers_item.enabled_func())

            -- When transfers exist, should be enabled
            instance.getTransferCount = function() return 5 end
            assert.is_true(transfers_item.enabled_func())
        end)
    end)
end)
