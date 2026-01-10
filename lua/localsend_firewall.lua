-- localsend_firewall.lua
-- Kindle firewall management for LocalSend plugin
-- Handles iptables rules for TCP/UDP ports

local constants = require("localsend_constants")

local M = {}

-- Dependencies container (set via M.init)
local deps = {}

-- Initialize module with dependencies
-- @param d table Dependencies: { Device, util, logger }
function M.init(d)
    deps = d
end

-- Check if an iptables rule exists (returns true if rule exists)
-- @param rule_args table Array of iptables arguments (e.g., {"INPUT", "-p", "tcp", "--dport", "53317", "-j", "ACCEPT"})
-- @return boolean True if rule exists, false otherwise
local function iptablesRuleExists(rule_args)
    -- Build command with -C (check) flag
    local cmd_args = {"iptables", "-C"}
    for _, arg in ipairs(rule_args) do
        table.insert(cmd_args, arg)
    end
    -- Use shell_escape for proper argument quoting
    local cmd = deps.util.shell_escape(cmd_args) .. " 2>/dev/null"
    local result = os.execute(cmd)
    return result == 0
end

-- Add iptables rule only if it doesn't already exist
-- @param rule_args table Array of iptables arguments (e.g., {"INPUT", "-p", "tcp", "--dport", "53317", "-j", "ACCEPT"})
-- @return boolean True if rule was added, false if it already existed
local function iptablesAddIfMissing(rule_args)
    if not iptablesRuleExists(rule_args) then
        -- Build command with -A (append) flag
        local cmd_args = {"iptables", "-A"}
        for _, arg in ipairs(rule_args) do
            table.insert(cmd_args, arg)
        end
        os.execute(deps.util.shell_escape(cmd_args))
        return true
    end
    return false
end

-- Delete iptables rule (silently ignores if rule doesn't exist)
-- @param rule_args table Array of iptables arguments
local function iptablesDelete(rule_args)
    local cmd_args = {"iptables", "-D"}
    for _, arg in ipairs(rule_args) do
        table.insert(cmd_args, arg)
    end
    os.execute(deps.util.shell_escape(cmd_args) .. " 2>/dev/null")
end

-- Open firewall ports for LocalSend
-- @param port string|number The port to open
-- @param use_webrtc boolean Whether to also open WebRTC ports
function M.openFirewall(port, use_webrtc)
    if not deps.Device:isKindle() then
        return
    end

    port = tostring(port)
    -- TCP for file transfer (idempotent - won't add if already exists)
    iptablesAddIfMissing({"INPUT", "-p", "tcp", "--dport", port,
        "-m", "conntrack", "--ctstate", "NEW,ESTABLISHED", "-j", "ACCEPT"})
    iptablesAddIfMissing({"OUTPUT", "-p", "tcp", "--sport", port,
        "-m", "conntrack", "--ctstate", "ESTABLISHED", "-j", "ACCEPT"})
    -- UDP for device discovery
    iptablesAddIfMissing({"INPUT", "-p", "udp", "--dport", port, "-j", "ACCEPT"})
    iptablesAddIfMissing({"OUTPUT", "-p", "udp", "--sport", port, "-j", "ACCEPT"})
    -- WebRTC/ICE UDP ports - must match range in peer.go SetEphemeralUDPPortRange
    if use_webrtc then
        iptablesAddIfMissing({"INPUT", "-p", "udp", "--dport", constants.WEBRTC_PORT_RANGE, "-j", "ACCEPT"})
        iptablesAddIfMissing({"OUTPUT", "-p", "udp", "--sport", constants.WEBRTC_PORT_RANGE, "-j", "ACCEPT"})
        deps.logger.dbg("[LocalSend] Firewall opened for WebRTC UDP ports (50000-50100)")
    end
    deps.logger.dbg("[LocalSend] Firewall opened for port " .. port)
end

-- Close firewall ports for LocalSend
-- @param port string|number The port to close
function M.closeFirewall(port)
    if not deps.Device:isKindle() then
        return
    end

    port = tostring(port)
    iptablesDelete({"INPUT", "-p", "tcp", "--dport", port,
        "-m", "conntrack", "--ctstate", "NEW,ESTABLISHED", "-j", "ACCEPT"})
    iptablesDelete({"OUTPUT", "-p", "tcp", "--sport", port,
        "-m", "conntrack", "--ctstate", "ESTABLISHED", "-j", "ACCEPT"})
    iptablesDelete({"INPUT", "-p", "udp", "--dport", port, "-j", "ACCEPT"})
    iptablesDelete({"OUTPUT", "-p", "udp", "--sport", port, "-j", "ACCEPT"})
    -- Clean up WebRTC UDP rules (ignore errors if they don't exist)
    iptablesDelete({"INPUT", "-p", "udp", "--dport", constants.WEBRTC_PORT_RANGE, "-j", "ACCEPT"})
    iptablesDelete({"OUTPUT", "-p", "udp", "--sport", constants.WEBRTC_PORT_RANGE, "-j", "ACCEPT"})
    deps.logger.dbg("[LocalSend] Firewall closed for port " .. port)
end

return M
