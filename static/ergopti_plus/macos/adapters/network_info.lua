--- adapters/network_info.lua

--- ==============================================================================
--- MODULE: NetworkInfo Adapter (Hammerspoon)
--- DESCRIPTION:
--- Hammerspoon implementation of the NetworkInfo port contract defined in
--- static/ergopti_plus/shared/ports/NetworkInfo.spec.js. Wraps hs.wifi and shell
--- commands to expose Wi-Fi SSID, signal strength, internet reachability, and
--- VPN detection without coupling domain modules to hs APIs.
---
--- FEATURES & RATIONALE:
--- 1. Hashed SSID: the raw SSID is never stored or returned to protect privacy;
---    getSsidHash() returns the SHA-256 digest so callers can compare known
---    networks without exposing the plaintext name.
--- 2. Null-on-disconnect: Wi-Fi methods return nil/null when no interface is
---    connected, matching the port contract error_behavior.
--- 3. Defensive pcall: all hs.wifi and shell calls are wrapped.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("lib.logger")

local LOG = "adapters.network_info"




-- =========================================
-- =========================================
-- ======= 1/ Internal Helpers =============
-- =========================================
-- =========================================

--- Computes the SHA-256 hex digest of a string via macOS openssl.
--- Returns "" on any failure.
--- @param s string Input string.
--- @return string
local function sha256_hex(s)
	if type(s) ~= "string" or s == "" then return "" end
	local ok, out = pcall(function()
		local cmd = string.format("printf '%%s' %q | openssl dgst -sha256 -hex 2>/dev/null", s)
		return hs.execute(cmd)
	end)
	if not ok or type(out) ~= "string" then return "" end
	return out:match("[0-9a-f]+%s*$"):gsub("%s+", "") or ""
end




-- =========================================
-- =========================================
-- ======= 2/ Adapter Methods ==============
-- =========================================
-- =========================================

--- Returns the SHA-256 hex digest of the active Wi-Fi SSID, or nil when not connected.
--- @return string|nil
function M.getSsidHash()
	local ok, result = pcall(function()
		local ssid = hs.wifi and hs.wifi.currentNetwork and hs.wifi.currentNetwork()
		if type(ssid) ~= "string" or ssid == "" then return nil end
		return sha256_hex(ssid)
	end)
	if not ok then
		Logger.error(LOG, "getSsidHash(): error — %s", tostring(result))
		return nil
	end
	return result
end

--- Returns the Wi-Fi signal quality as an integer 0-100, or nil when not connected.
--- @return number|nil
function M.getSignalStrength()
	local ok, result = pcall(function()
		local rssi = hs.wifi and hs.wifi.interfaceDetails and (function()
			local details = hs.wifi.interfaceDetails()
			return details and details.rssi
		end)()
		if type(rssi) ~= "number" then return nil end
		-- Convert dBm (-100 to 0) to 0-100 percentage
		local clamped = math.max(-100, math.min(0, rssi))
		return math.floor((clamped + 100))
	end)
	if not ok then
		Logger.error(LOG, "getSignalStrength(): error — %s", tostring(result))
		return nil
	end
	return result
end

--- Returns whether the host has a working internet connection.
--- @return boolean
function M.isInternetReachable()
	local ok, result = pcall(function()
		local out = hs.execute("ping -c 1 -t 1 8.8.8.8 2>/dev/null")
		return type(out) == "string" and out:find("1 packets received") ~= nil
	end)
	if not ok then
		Logger.error(LOG, "isInternetReachable(): error — %s", tostring(result))
		return false
	end
	return result == true
end

--- Returns whether at least one VPN adapter is currently up.
--- @return boolean
function M.isVpnActive()
	local ok, result = pcall(function()
		local out = hs.execute("ifconfig 2>/dev/null | grep -c 'utun[0-9]'")
		if type(out) ~= "string" then return false end
		local count = tonumber(out:match("%d+")) or 0
		return count > 0
	end)
	if not ok then
		Logger.error(LOG, "isVpnActive(): error — %s", tostring(result))
		return false
	end
	return result == true
end

return M
