-- LocalSend utility functions
-- Extracted for testability

local M = {}

-- Shell escape utility to prevent command injection
-- Wraps string in single quotes and escapes any embedded single quotes
function M.shellEscape(str)
    if str == nil then return "''" end
    -- Single quote escape: replace ' with '\''
    return "'" .. str:gsub("'", "'\\''") .. "'"
end

-- Validate that a path is safe for shell operations
function M.isValidPath(path)
    if path == nil or path == "" then return false end
    -- Reject paths with null bytes
    if path:find("%z") then return false end
    -- Must be absolute path
    if not path:match("^/") then return false end
    -- No command substitution patterns
    if path:find("`") or path:find("%$%(") then return false end
    return true
end

-- Validate that a port number is safe for shell operations
function M.isValidPort(port)
    if port == nil then return false end
    local num = tonumber(port)
    if num == nil then return false end
    if num < 1 or num > 65535 then return false end
    -- Ensure it's an integer
    if num ~= math.floor(num) then return false end
    return true
end

-- Compare semantic versions
-- Returns: -1 if v1 < v2, 0 if equal, 1 if v1 > v2
function M.compareVersions(v1, v2)
    local function parseVersion(v)
        local parts = {}
        for num in string.gmatch(v:gsub("^v", ""), "(%d+)") do
            table.insert(parts, tonumber(num) or 0)
        end
        return parts
    end

    local p1, p2 = parseVersion(v1), parseVersion(v2)
    for i = 1, math.max(#p1, #p2) do
        local n1, n2 = p1[i] or 0, p2[i] or 0
        if n1 < n2 then return -1 end
        if n1 > n2 then return 1 end
    end
    return 0
end

-- Find download asset URL for given architecture
function M.findAssetForArch(assets, arch)
    local pattern = "localsend%-koplugin%-" .. arch .. "%.zip$"
    for _, asset in ipairs(assets) do
        if asset.name and asset.name:match(pattern) then
            return asset.browser_download_url, asset.name
        end
    end
    return nil, nil
end

-- Validate device name for LocalSend
function M.validateDeviceName(name)
    -- Empty name is valid (will use random name)
    if name == "" then
        return true
    end

    -- Check length (reasonable limit)
    if #name > 64 then
        return false, "Device name is too long (max 64 characters)."
    end

    -- Only allow alphanumeric, spaces, hyphens, underscores, and apostrophes (straight and curly)
    if not name:match("^[%w%s%-_''']+$") then
        return false, "Device name can only contain letters, numbers, spaces, hyphens, underscores, and apostrophes."
    end

    return true
end

return M
