--- adapters/network_info.lua

--- ==============================================================================
--- MODULE: NetworkInfo Adapter (Hammerspoon)
--- DESCRIPTION:
--- Hammerspoon implementation of the NetworkInfo port contract defined in
--- static/ergopti_plus/_shared/core/ports/NetworkInfo.spec.js. Wraps hs.wifi and shell
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
--- 4. Non-blocking shell-outs: isInternetReachable() and isVpnActive() require a
---    `ping`/`ifconfig` subprocess — the port contract mandates a synchronous
---    boolean return, so a blocking hs.execute() on the main run loop would stall
---    every other Hammerspoon callback for up to the ping timeout (F-LOW-8).
---    Both methods instead return the last cached probe result immediately and
---    kick off an async refresh via adapters.shell_runner (mirrors the
---    read_layout_async() cached-async pattern in platform/remap/watchers.lua)
---    so the NEXT call reflects reality without ever blocking the caller.
--- ==============================================================================

local M = {}

local hs          = hs
local Logger      = require("infra.logger")
local ShellRunner = require("adapters.shell_runner")
local Crypto      = require("adapters.crypto")

local LOG = "adapters.network_info"

-- Absolute binary paths — adapters.shell_runner.spawn() takes no shell, so the
-- executable must be resolved ahead of time (macOS ships both under /sbin).
local PING_BIN     = "/sbin/ping"
local IFCONFIG_BIN = "/sbin/ifconfig"

-- ping's own deadline in seconds before giving up on a reply (kept short so a
-- probe refresh cannot pile up if the network is genuinely unreachable).
local PING_TIMEOUT_SEC = 1




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
	return Crypto.sha256(s)
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

-- Last known probe results, updated asynchronously by _refresh_*(). Both start
-- false — the first call always kicks off a refresh and reports the safe
-- (unreachable / no VPN) default until that refresh lands.
local _cached_internet_reachable = false
local _cached_vpn_active         = false
local _has_internet_probe_result = false

-- Guards against piling up a second in-flight probe while one is still
-- running (e.g. isInternetReachable() polled faster than the ping timeout).
local _internet_probe_inflight = false
local _vpn_probe_inflight      = false

--- Kicks off an async `ping` probe and updates _cached_internet_reachable when
--- it completes. Fire-and-forget — never blocks the caller.
local function _refresh_internet_reachable()
	if _internet_probe_inflight then return end
	_internet_probe_inflight = true

	local handle = ShellRunner.spawn(PING_BIN,
		{ "-c", "1", "-t", tostring(PING_TIMEOUT_SEC), "8.8.8.8" },
		function(exit_code, stdout, _stderr)
			_internet_probe_inflight = false
			_cached_internet_reachable = exit_code == 0
				and type(stdout) == "string"
				and stdout:find("1 packets received") ~= nil
			_has_internet_probe_result = true
			Logger.debug(LOG, "isInternetReachable() refreshed: %s", tostring(_cached_internet_reachable))
		end)
	-- The adapter logs a launch failure but does not raise, so pcall alone always
	-- reports success. Branching on the returned boolean too is what releases the
	-- latch: otherwise a probe that never launched leaves _internet_probe_inflight
	-- set forever and every later call short-circuits on the guard above, freezing
	-- isInternetReachable() at false for the whole process lifetime.
	local ok, started = pcall(function() return handle.start() end)
	if not ok or started ~= true then
		_internet_probe_inflight = false
		Logger.error(LOG, "isInternetReachable(): failed to start async ping probe — %s", tostring(started))
	end
end

--- Kicks off an async `ifconfig` probe and updates _cached_vpn_active when it
--- completes. Fire-and-forget — never blocks the caller.
local function _refresh_vpn_active()
	if _vpn_probe_inflight then return end
	_vpn_probe_inflight = true

	local handle = ShellRunner.spawn(IFCONFIG_BIN, {},
		function(exit_code, stdout, _stderr)
			_vpn_probe_inflight = false
			if exit_code ~= 0 or type(stdout) ~= "string" then
				_cached_vpn_active = false
				return
			end
			-- Count utun* interfaces directly in Lua — no grep subprocess needed
			-- now that we already have the full ifconfig output in-process.
			local count = 0
			for _ in stdout:gmatch("utun%d+") do count = count + 1 end
			_cached_vpn_active = count > 0
			Logger.debug(LOG, "isVpnActive() refreshed: %s", tostring(_cached_vpn_active))
		end)
	-- Same latch release as the ping probe above: a logged-only launch failure is
	-- invisible to pcall, so _vpn_probe_inflight must also be cleared when the
	-- adapter reports it did not start the subprocess.
	local ok, started = pcall(function() return handle.start() end)
	if not ok or started ~= true then
		_vpn_probe_inflight = false
		Logger.error(LOG, "isVpnActive(): failed to start async ifconfig probe — %s", tostring(started))
	end
end

--- Returns whether the host has a working internet connection.
--- Never blocks: returns the last cached probe result immediately and kicks off
--- an async refresh (via adapters.shell_runner) so the NEXT call is current.
--- @return boolean
function M.isInternetReachable()
	_refresh_internet_reachable()
	return _cached_internet_reachable == true
end

--- Returns whether an asynchronous internet probe has completed at least once.
--- @return boolean True after the cached reachability result is authoritative.
function M.hasInternetProbeResult()
	return _has_internet_probe_result == true
end

--- Returns whether at least one VPN adapter is currently up.
--- Never blocks: returns the last cached probe result immediately and kicks off
--- an async refresh (via adapters.shell_runner) so the NEXT call is current.
--- @return boolean
function M.isVpnActive()
	_refresh_vpn_active()
	return _cached_vpn_active == true
end

return M
