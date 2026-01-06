-- localsend_dialogs.lua
-- UI dialog helpers for LocalSend plugin
-- Handles save directory picker, device name, PIN, and extension dialogs

local M = {}

-- Extension presets for allowed extensions menu
M.EXTENSION_PRESETS = {
    { name = "All files", value = "" },
    { name = "eBooks (epub, pdf, mobi, azw3)", value = "epub,pdf,mobi,azw3" },
    { name = "eBooks + CBZ (comics)", value = "epub,pdf,mobi,azw3,cbz,cbr" },
    { name = "PDF only", value = "pdf" },
    { name = "EPUB only", value = "epub" },
    { name = "Custom...", value = nil },
}

-- Dependencies container (set via M.init)
local deps = {}

-- Initialize module with dependencies
-- @param d table Dependencies: { UIManager, InfoMessage, InputDialog, PathChooser, util, logger, T, _, G_reader_settings }
function M.init(d)
    deps = d
    -- Translate preset names after gettext is available
    M.EXTENSION_PRESETS = {
        { name = deps._("All files"), value = "" },
        { name = deps._("eBooks (epub, pdf, mobi, azw3)"), value = "epub,pdf,mobi,azw3" },
        { name = deps._("eBooks + CBZ (comics)"), value = "epub,pdf,mobi,azw3,cbz,cbr" },
        { name = deps._("PDF only"), value = "pdf" },
        { name = deps._("EPUB only"), value = "epub" },
        { name = deps._("Custom..."), value = nil },
    }
end

-- Get the starting path for path picker (handles home folder lock workaround)
-- @param path string The target path
-- @return string The starting path for the picker
function M.getPickerStartPath(path)
    -- Only apply workaround if home folder lock is enabled
    if not deps.G_reader_settings:isTrue("lock_home_folder") then
        return path
    end

    -- Check if save_dir is at or inside the locked home folder
    local home_dir = deps.G_reader_settings:readSetting("home_dir")
    if home_dir then
        -- Normalize paths (remove trailing slashes for comparison)
        local norm_path = path:gsub("/$", "")
        local norm_home = home_dir:gsub("/$", "")
        -- Escape Lua pattern special characters for matching
        local escaped_home = norm_home:gsub("([%.%-%+%[%]%(%)%$%^%%%?%*])", "%%%1")
        -- If save_dir doesn't start with home_dir, no workaround needed
        if norm_path ~= norm_home and not norm_path:match("^" .. escaped_home .. "/") then
            return path
        end
    end

    -- If already at root, stay there
    if path == "/" then
        return path
    end

    -- Remove trailing slash if present (except for root)
    path = path:gsub("/$", "")

    -- Get parent directory
    local parent = path:match("^(.+)/[^/]+$")
    if not parent or parent == "" then
        -- Path is like "/foo" so parent would be root
        parent = "/"
    end

    -- Check if parent directory exists and is accessible
    if deps.util.pathExists(parent) then
        return parent
    end

    -- Parent doesn't exist or isn't accessible, fall back to original path
    return path
end

-- Show directory picker for save location
-- @param instance table LocalSend instance
-- @param touchmenu_instance table Touch menu instance for updates
function M.showSaveDirPicker(instance, touchmenu_instance)
    local start_path = instance:getPickerStartPath(instance.save_dir)
    local path_chooser = deps.PathChooser:new{
        select_directory = true,
        select_file = false,
        path = start_path,
        onConfirm = function(path)
            local valid, err = instance:validateSaveDir(path)
            if valid then
                instance.save_dir = path
                deps.G_reader_settings:saveSetting("LocalSend_save_dir", instance.save_dir)
                touchmenu_instance:updateItems()
            else
                deps.UIManager:show(deps.InfoMessage:new{
                    icon = "notice-warning",
                    text = deps.T(deps._("Cannot use this directory: %1"), err),
                })
            end
        end,
    }
    deps.UIManager:show(path_chooser)
end

-- Show input dialog for device name
-- @param instance table LocalSend instance
-- @param touchmenu_instance table Touch menu instance for updates
function M.showDeviceNameDialog(instance, touchmenu_instance)
    local dialog
    dialog = deps.InputDialog:new{
        title = deps._("Device name"),
        description = deps._("Leave empty for default ('KOReader')"),
        input = instance.device_name,
        input_hint = "My Kindle",
        buttons = {
            {
                {
                    text = deps._("Cancel"),
                    id = "close",
                    callback = function()
                        deps.UIManager:close(dialog)
                    end,
                },
                {
                    text = deps._("Save"),
                    is_enter_default = true,
                    callback = function()
                        local new_name = dialog:getInputText()
                        local valid, err = instance:validateDeviceName(new_name)
                        if not valid then
                            deps.UIManager:show(deps.InfoMessage:new{
                                icon = "notice-warning",
                                text = err,
                            })
                            return
                        end
                        instance.device_name = new_name
                        deps.G_reader_settings:saveSetting("LocalSend_device_name", instance.device_name)
                        deps.UIManager:close(dialog)
                        touchmenu_instance:updateItems()
                    end,
                },
            },
        },
    }
    deps.UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Show input dialog for PIN code
-- @param instance table LocalSend instance
-- @param touchmenu_instance table Touch menu instance for updates
function M.showPinDialog(instance, touchmenu_instance)
    local dialog
    dialog = deps.InputDialog:new{
        title = deps._("PIN code"),
        description = deps._("Leave empty to disable PIN protection"),
        input = instance.pin,
        input_hint = "1234",
        buttons = {
            {
                {
                    text = deps._("Cancel"),
                    id = "close",
                    callback = function()
                        deps.UIManager:close(dialog)
                    end,
                },
                {
                    text = deps._("Save"),
                    is_enter_default = true,
                    callback = function()
                        instance.pin = dialog:getInputText()
                        deps.G_reader_settings:saveSetting("LocalSend_pin", instance.pin)
                        deps.UIManager:close(dialog)
                        touchmenu_instance:updateItems()
                    end,
                },
            },
        },
    }
    deps.UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Show input dialog for custom extensions
-- @param instance table LocalSend instance
function M.showCustomExtDialog(instance)
    local dialog
    dialog = deps.InputDialog:new{
        title = deps._("Custom extensions"),
        description = deps._("Comma-separated list (e.g., 'epub,pdf,mobi')"),
        input = instance.accept_ext,
        input_hint = "epub,pdf,mobi",
        buttons = {
            {
                {
                    text = deps._("Cancel"),
                    id = "close",
                    callback = function()
                        deps.UIManager:close(dialog)
                    end,
                },
                {
                    text = deps._("Save"),
                    is_enter_default = true,
                    callback = function()
                        instance.accept_ext = dialog:getInputText()
                        deps.G_reader_settings:saveSetting("LocalSend_accept_ext", instance.accept_ext)
                        deps.UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    deps.UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Build extension presets menu
-- @param instance table LocalSend instance
-- @return table Menu items
function M.buildExtensionPresetsMenu(instance)
    local menu = {}
    for _, preset in ipairs(M.EXTENSION_PRESETS) do
        if preset.value == nil then
            -- Custom option
            table.insert(menu, {
                text = preset.name,
                keep_menu_open = true,
                callback = function()
                    instance:showCustomExtDialog()
                end,
            })
        else
            table.insert(menu, {
                text = preset.name,
                checked_func = function()
                    return instance.accept_ext == preset.value
                end,
                callback = function()
                    instance.accept_ext = preset.value
                    deps.G_reader_settings:saveSetting("LocalSend_accept_ext", instance.accept_ext)
                end,
            })
        end
    end
    return menu
end

return M
