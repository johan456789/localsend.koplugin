-- localsend_update.lua
-- Update system for LocalSend plugin
-- Handles checking for updates, downloading, and installing

local lsutils = require("localsend_utils")

local M = {}

-- Constants
M.GITHUB_RELEASE_URL = "https://api.github.com/repos/kaikozlov/localsend.koplugin/releases/latest"

-- Dependencies container (set via M.init)
local deps = {}

-- Initialize module with dependencies
-- @param d table Dependencies: { UIManager, InfoMessage, NetworkMgr, util, json, logger, T, _ }
function M.init(d)
    deps = d
end

-- Build a curl command for fetching JSON from a URL
-- @param output_file string Path to write response body
-- @param url string URL to fetch
-- @return string Shell-escaped curl command that outputs HTTP status code
function M.buildCurlCommand(output_file, url)
    return deps.util.shell_escape({
        "curl", "-s",
        "-o", output_file,
        "-w", "%{http_code}",
        "--connect-timeout", "10",
        "-H", "Accept: application/vnd.github.v3+json",
        url
    })
end

-- Detect device architecture for selecting the right binary
-- @return string|nil Architecture name: "arm64", "armv7", "arm-legacy", or nil
function M.getDeviceArch()
    local handle = io.popen("uname -m")
    if not handle then return nil end
    local ok, arch = pcall(handle.read, handle, "*l")
    handle:close()
    if not ok then return nil end

    if not arch then return nil end

    -- Map uname output to our asset naming
    -- arm64/aarch64: 64-bit ARM (newer devices)
    -- armv7: 32-bit ARM with hardware float (most Kindles PW1+, returns "armv7l")
    -- armv5: legacy 32-bit ARM with soft float (K3, K4, older devices)
    if arch:match("^aarch64") or arch:match("^arm64") then
        return "arm64"
    elseif arch:match("^armv7") then
        return "armv7"
    elseif arch:match("^armv[56]") or arch:match("^arm") then
        -- armv5, armv6, or generic "arm" -> use legacy armv5 binary
        return "arm-legacy"
    end

    return nil
end

-- Perform the actual update download and installation
-- @param instance table LocalSend instance
-- @param download_url string URL to download
-- @param asset_name string Name of the asset
-- @param new_version string Version string
-- @param plugin_path string Path to plugin directory
function M.doPerformUpdate(instance, download_url, asset_name, new_version, plugin_path)
    local tmp_zip = "/tmp/localsend_update.zip"
    local tmp_extract = "/tmp/localsend_update_extract"

    -- Clean up any previous update attempt
    os.remove(tmp_zip)
    os.execute(deps.util.shell_escape({"rm", "-rf", tmp_extract}))

    -- Download the zip
    local cmd = deps.util.shell_escape({"curl", "-L", "-s", "-o", tmp_zip, "-w", "%{http_code}",
        "--connect-timeout", "30", "--max-time", "120", download_url})

    local handle = io.popen(cmd)
    if not handle then
        deps.UIManager:show(deps.InfoMessage:new{
            icon = "notice-warning",
            text = deps._("Failed to execute download command."),
        })
        return
    end
    local http_code = handle:read("*a")
    handle:close()

    if http_code ~= "200" then
        deps.UIManager:show(deps.InfoMessage:new{
            icon = "notice-warning",
            text = deps.T(deps._("Download failed.\nHTTP status: %1"), http_code),
        })
        os.remove(tmp_zip)
        return
    end

    -- Verify zip was downloaded
    if not deps.util.pathExists(tmp_zip) then
        deps.UIManager:show(deps.InfoMessage:new{
            icon = "notice-warning",
            text = deps._("Download failed: file not saved."),
        })
        return
    end

    -- Create extraction directory
    deps.util.makePath(tmp_extract)

    -- Extract the zip
    local result = os.execute(deps.util.shell_escape({"unzip", "-o", tmp_zip, "-d", tmp_extract}))

    if result ~= 0 then
        deps.UIManager:show(deps.InfoMessage:new{
            icon = "notice-warning",
            text = deps._("Failed to extract update."),
        })
        os.remove(tmp_zip)
        os.execute(deps.util.shell_escape({"rm", "-rf", tmp_extract}))
        return
    end

    -- The zip contains localsend.koplugin/ folder
    local extracted_plugin = tmp_extract .. "/localsend.koplugin"

    if not deps.util.pathExists(extracted_plugin) then
        deps.UIManager:show(deps.InfoMessage:new{
            icon = "notice-warning",
            text = deps._("Invalid update package structure."),
        })
        os.remove(tmp_zip)
        os.execute(deps.util.shell_escape({"rm", "-rf", tmp_extract}))
        return
    end

    -- Copy files to plugin directory
    -- Core files that must exist:
    local files_to_copy = { "main.lua", "_meta.lua", "localsend" }
    local copy_failed = false

    for _, file in ipairs(files_to_copy) do
        local src = extracted_plugin .. "/" .. file
        local dst = plugin_path .. "/" .. file

        if deps.util.pathExists(src) then
            local cp_result = os.execute(deps.util.shell_escape({"cp", src, dst}))
            if cp_result ~= 0 then
                copy_failed = true
                deps.logger.err("[LocalSend] Failed to copy:", file)
            end
        else
            deps.logger.warn("[LocalSend] File not in update package:", file)
        end
    end

    -- Also copy any additional .lua files (for future-proofing)
    local ls_handle = io.popen(deps.util.shell_escape({"ls"}) .. " " .. deps.util.shell_escape({extracted_plugin}) .. "/*.lua 2>/dev/null")
    if ls_handle then
        local process_ok, process_err = pcall(function()
            for lua_file in ls_handle:lines() do
                local _, filename = deps.util.splitFilePathName(lua_file)
                -- Skip files we already copied
                if filename and filename ~= "main.lua" and filename ~= "_meta.lua" then
                    local dst = plugin_path .. "/" .. filename
                    local cp_result = os.execute(deps.util.shell_escape({"cp", lua_file, dst}))
                    if cp_result ~= 0 then
                        deps.logger.warn("[LocalSend] Failed to copy additional lua file:", filename)
                    else
                        deps.logger.dbg("[LocalSend] Copied additional lua file:", filename)
                    end
                end
            end
        end)
        ls_handle:close()
        if not process_ok then
            deps.logger.err("[LocalSend] Error processing lua files:", process_err)
        end
    end

    -- Make binary executable
    os.execute(deps.util.shell_escape({"chmod", "+x", plugin_path .. "/localsend"}))

    -- Cleanup
    os.remove(tmp_zip)
    os.execute(deps.util.shell_escape({"rm", "-rf", tmp_extract}))

    if copy_failed then
        deps.UIManager:show(deps.InfoMessage:new{
            icon = "notice-warning",
            text = deps._("Update partially failed. Some files could not be copied. Please update manually."),
        })
        return
    end

    -- Success!
    deps.UIManager:show(deps.InfoMessage:new{
        text = deps.T(deps._("Update to %1 installed successfully!\n\nPlease restart KOReader for changes to take effect."), new_version),
    })
end

-- Start update process with UI feedback
-- @param instance table LocalSend instance
-- @param download_url string URL to download
-- @param asset_name string Name of the asset
-- @param new_version string Version string
-- @param plugin_path string Path to plugin directory
function M.performUpdate(instance, download_url, asset_name, new_version, plugin_path)
    -- Stop server if running
    if instance:isRunning() then
        instance:stopServer()
    end

    deps.UIManager:show(deps.InfoMessage:new{
        text = deps._("Downloading update..."),
        timeout = 2,
    })

    -- Give UI time to show the message
    deps.UIManager:scheduleIn(0.5, function()
        M.doPerformUpdate(instance, download_url, asset_name, new_version, plugin_path)
    end)
end

-- Calculate seconds until next update check
-- @param last_check number Timestamp of last check
-- @param interval_hours number Check interval in hours
-- @return number Delay in seconds
function M.getUpdateCheckDelay(last_check, interval_hours)
    local now = os.time()
    local interval_seconds = interval_hours * 3600
    local time_since_last = now - last_check
    local delay = interval_seconds - time_since_last
    -- If we're past due, schedule a short delay (60s) to not flood on startup
    if delay <= 0 then
        return 60  -- 1 minute delay for startup
    end
    return delay
end

-- Perform silent auto-check for updates
-- @param instance table LocalSend instance
-- @param plugin_version string Current plugin version
-- @param schedule_next function Callback to schedule next check
function M.doAutoCheckForUpdates(instance, plugin_version, schedule_next)
    local tmp_file = "/tmp/localsend_update_check.json"
    local cmd = M.buildCurlCommand(tmp_file, M.GITHUB_RELEASE_URL)

    local handle = io.popen(cmd)
    if not handle then
        deps.logger.dbg("[LocalSend] Auto update check failed: io.popen returned nil")
        schedule_next()
        return
    end
    local ok, http_code = pcall(handle.read, handle, "*a")
    handle:close()
    if not ok then
        deps.logger.dbg("[LocalSend] Auto update check failed: read error")
        schedule_next()
        return
    end

    -- Update last check time regardless of result
    instance.last_update_check = os.time()
    deps.G_reader_settings:saveSetting("LocalSend_last_update_check", instance.last_update_check)

    if http_code ~= "200" then
        deps.logger.dbg("[LocalSend] Auto update check failed, HTTP:", http_code)
        os.remove(tmp_file)
        schedule_next()
        return
    end

    local content = deps.util.readFromFile(tmp_file)
    os.remove(tmp_file)

    if not content then
        schedule_next()
        return
    end

    local decode_ok, release = pcall(deps.json.decode, content)
    if not decode_ok or not release or not release.tag_name then
        schedule_next()
        return
    end

    local latest_version = release.tag_name:gsub("^v", "")
    local current_version = plugin_version:gsub("^v", "")

    -- Check if update available
    if lsutils.compareVersions(current_version, latest_version) < 0 then
        -- Show update notification (modal, requires dismissal)
        deps.UIManager:show(deps.InfoMessage:new{
            text = deps.T(deps._("LocalSend update available: %1\nGo to LocalSend menu to install."), release.tag_name),
        })
    end

    -- Schedule next check
    schedule_next()
end

-- Perform manual check for updates with UI feedback
-- @param instance table LocalSend instance
-- @param plugin_version string Current plugin version
-- @param plugin_path string Path to plugin directory
function M.doCheckForUpdates(instance, plugin_version, plugin_path)
    deps.UIManager:show(deps.InfoMessage:new{
        text = deps._("Checking for updates..."),
        timeout = 2,
    })

    local tmp_file = "/tmp/localsend_update_check.json"
    local cmd = M.buildCurlCommand(tmp_file, M.GITHUB_RELEASE_URL)

    local handle = io.popen(cmd)
    if not handle then
        deps.UIManager:show(deps.InfoMessage:new{
            icon = "notice-warning",
            text = deps._("Failed to execute update check command."),
        })
        return
    end
    local ok, http_code = pcall(handle.read, handle, "*a")
    handle:close()
    if not ok then
        deps.UIManager:show(deps.InfoMessage:new{
            icon = "notice-warning",
            text = deps._("Failed to read update check response."),
        })
        return
    end

    if http_code ~= "200" then
        deps.UIManager:show(deps.InfoMessage:new{
            icon = "notice-warning",
            text = deps.T(deps._("Failed to check for updates.\nHTTP status: %1\n\nPlease check your internet connection."), http_code),
        })
        os.remove(tmp_file)
        return
    end

    local content = deps.util.readFromFile(tmp_file)
    os.remove(tmp_file)

    if not content then
        deps.UIManager:show(deps.InfoMessage:new{
            icon = "notice-warning",
            text = deps._("Failed to read update information."),
        })
        return
    end

    local decode_ok, release = pcall(deps.json.decode, content)
    if not decode_ok or not release or not release.tag_name then
        deps.UIManager:show(deps.InfoMessage:new{
            icon = "notice-warning",
            text = deps._("Failed to parse update information."),
        })
        return
    end

    local latest_version = release.tag_name:gsub("^v", "")
    local current_version = plugin_version:gsub("^v", "")

    if lsutils.compareVersions(current_version, latest_version) >= 0 then
        deps.UIManager:show(deps.InfoMessage:new{
            text = deps.T(deps._("You're up to date!\n\nCurrent version: %1\nLatest version: %2"), plugin_version, release.tag_name),
            timeout = 5,
        })
    else
        -- Update available - check if we can auto-update
        local arch = M.getDeviceArch()
        local download_url, asset_name

        if arch and release.assets then
            download_url, asset_name = lsutils.findAssetForArch(release.assets, arch)
        end

        local release_notes = release.body or deps._("No release notes available.")
        -- Truncate if too long
        if #release_notes > 300 then
            release_notes = release_notes:sub(1, 300) .. "..."
        end

        if download_url then
            -- Can auto-update
            local ConfirmBox = require("ui/widget/confirmbox")
            deps.UIManager:show(ConfirmBox:new{
                text = deps.T(deps._("Update available!\n\nCurrent: %1\nLatest: %2\n\n%3\n\nInstall update now?"),
                    plugin_version, release.tag_name, release_notes),
                ok_text = deps._("Install"),
                cancel_text = deps._("Later"),
                ok_callback = function()
                    M.performUpdate(instance, download_url, asset_name, release.tag_name, plugin_path)
                end,
            })
        else
            -- Can't auto-update (unknown arch or no matching asset)
            local reason
            if not arch then
                reason = deps._("\n\nAuto-update not available: unknown device architecture.")
            else
                reason = deps.T(deps._("\n\nAuto-update not available: no package for %1 architecture."), arch)
            end

            deps.UIManager:show(deps.InfoMessage:new{
                text = deps.T(deps._("Update available!\n\nCurrent: %1\nLatest: %2\n\n%3%4\n\nVisit GitHub to download manually."),
                    plugin_version, release.tag_name, release_notes, reason),
            })
        end
    end
end

-- Check for updates (handles network prompting)
-- @param instance table LocalSend instance
-- @param plugin_version string Current plugin version
-- @param plugin_path string Path to plugin directory
function M.checkForUpdates(instance, plugin_version, plugin_path)
    deps.NetworkMgr:runWhenOnline(function()
        M.doCheckForUpdates(instance, plugin_version, plugin_path)
    end)
end

return M
