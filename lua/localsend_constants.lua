-- localsend_constants.lua
-- Shared constants for LocalSend plugin modules
-- This module provides a single source of truth for constants used across multiple modules

local M = {}

-- File paths (temporary files for server lifecycle)
M.PID_FILE = "/tmp/localsend_koreader.pid"
M.TRANSFER_LOG_FILE = "/tmp/localsend_transfers.log"
M.TRANSFER_NOTIFY_FILE = "/tmp/localsend_notify"

-- Polling intervals (seconds)
M.SENTINEL_POLL_INTERVAL = 2

-- Network defaults
M.DEFAULT_PORT = "53317"
M.DEFAULT_SAVE_DIR = "/mnt/us/documents"
M.WEBRTC_PORT_RANGE = "50000:50100"

-- Update check defaults
M.DEFAULT_UPDATE_CHECK_INTERVAL_HOURS = 168  -- Weekly

return M
