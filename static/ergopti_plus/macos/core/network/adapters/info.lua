--- core/network/adapters/info.lua

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
---    read_layout_async() cached-async pattern in keyboard/engine/runtime/watchers.lua)
---    so the NEXT call reflects reality without ever blocking the caller.
--- 5. Connectivity transitions (keystats events_network) read two tri-state
---    probes that need no permission: SCNetworkReachability resolving the
---    Windows NCSI host through the system resolver, scheduled on the run loop
---    so its answer arrives by callback, and the asynchronous ifconfig read of
---    the tunnel interfaces (utun, ipsec, ppp). A probe that cannot answer is
---    "unknown", never "down".
--- ==============================================================================

local M = {}

local hs          = hs
local Logger      = require("core.logger.engine.logger")
local ShellRunner = require("core.process.adapters.shell_runner")
local Crypto      = require("core.crypto.crypto")
local NumberPolicy = require("core.text.engine.number_policy")

local LOG = "core.network.adapters.info"

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

--- Computes the SHA-256 hex digest of a string via the native hash adapter.
--- Returns nil on failure, as required by the network information contract.
--- @param s string Input string.
--- @return string|nil
local function sha256_hex(s)
	local digest = Crypto.sha256(s)
	if digest == "" then return nil end
	return digest
end

--- Interface names macOS gives VPN tunnels: Network Extension and WireGuard
--- (utun), the legacy IPsec client (ipsec) and L2TP/PPTP (ppp).
local TUNNEL_INTERFACE_PATTERNS = { "^utun%d+$", "^ipsec%d+$", "^ppp%d+$" }

--- Whether an interface name is a tunnel kind.
--- @param name string Interface name.
--- @return boolean
local function is_tunnel_interface(name)
	for _, pattern in ipairs(TUNNEL_INTERFACE_PATTERNS) do
		if name:match(pattern) then return true end
	end
	return false
end

--- Returns whether an ifconfig snapshot contains an up tunnel interface carrying
--- a non-link-local address in that interface's own block. macOS keeps
--- baseline utun devices around without an active VPN, so the interface name
--- alone is not evidence of a live tunnel.
--- @param stdout string Complete ifconfig output.
--- @return boolean
local function has_active_vpn_interface(stdout)
	if type(stdout) ~= "string" then return false end

	local current_tunnel_is_up = false
	for raw_line in (stdout .. "\n"):gmatch("(.-)\n") do
		local line = raw_line:gsub("\r$", "")
		local interface = line:match("^([^%s:]+):")
		if interface then
			local flags = line:match("flags=[^<]*<([^>]*)>") or ""
			current_tunnel_is_up = is_tunnel_interface(interface)
				and ("," .. flags .. ","):find(",UP,", 1, true) ~= nil
		elseif current_tunnel_is_up then
			local ipv4 = line:match("^%s*inet%s+([%d%.]+)")
			if ipv4 and not ipv4:match("^169%.254%.") then return true end

			local ipv6 = line:match("^%s*inet6%s+([^%s%%]+)")
			if ipv6 then
				local first_hextet_raw = ipv6:match("^([%x]+):")
				local first_hextet = first_hextet_raw and tonumber(first_hextet_raw, 16) or nil
				local is_link_local = first_hextet ~= nil
					and first_hextet >= 0xFE80
					and first_hextet <= 0xFEBF
				if first_hextet ~= nil and not is_link_local then return true end
			end
		end
	end

	return false
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
		local ssid = hs.wifi and hs.wifi.currentNetwork and hs.wifi.currentNetwork()
		-- CoreWLAN can retain interface details after the connection disappears.
		if type(ssid) ~= "string" or ssid == "" then return nil end
		local rssi = hs.wifi and hs.wifi.interfaceDetails and (function()
			local details = hs.wifi.interfaceDetails()
			return details and details.rssi
		end)()
		if not NumberPolicy.is_finite(rssi) then return nil end
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
			_cached_vpn_active = has_active_vpn_interface(stdout)
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




-- =========================================
-- =========================================
-- ======= 3/ Connectivity Probes ==========
-- =========================================
-- =========================================

-- Reachability targets kept alive while watched: a collected target stops calling back.
local _reachability_watches = {}

--- Classifies SCNetworkReachability flags: reachable without first having to
--- establish a connection is "up", anything else is "down".
--- @param flags number|nil Reachability flags.
--- @return string status "up", "down" or "unknown".
function M.classify_reachability_flags(flags)
	if math.type(flags) ~= "integer" then return "unknown" end
	local names = hs.network.reachability.flags
	local reachable = (flags & names.reachable) ~= 0
	local needs_connection = (flags & names.connectionRequired) ~= 0
	return (reachable and not needs_connection) and "up" or "down"
end

--- Watches a host's reachability; the system resolves it off the run loop and
--- calls back on each change of flags.
--- @param host string Host name to resolve.
--- @param on_status fun(status) Receives "up", "down" or "unknown".
--- @return table watch { stop }
function M.watch_host_reachability(host, on_status)
	assert(type(host) == "string" and host ~= "" and type(on_status) == "function",
		"a reachability watch needs a host and a callback")
	local target = assert(hs.network.reachability.forHostName(host), "no reachability target for " .. host)
	target:setCallback(function(_, flags) on_status(M.classify_reachability_flags(flags)) end)
	assert(target:start(), "the reachability target for " .. host .. " did not start")
	_reachability_watches[target] = true
	local watch = {}
	function watch.stop()
		if not _reachability_watches[target] then return end
		_reachability_watches[target] = nil
		target:stop()
	end
	return watch
end

--- Reads the tunnel interfaces asynchronously.
--- @param answer fun(status) Receives "up" when a tunnel carries an address,
---   "down" when none does, "unknown" when ifconfig failed.
--- @return boolean started False when the subprocess could not start.
function M.probe_vpn_status(answer)
	assert(type(answer) == "function", "the VPN probe needs a callback")
	local handle = ShellRunner.spawn(IFCONFIG_BIN, {}, function(exit_code, stdout, _stderr)
		if exit_code ~= 0 or type(stdout) ~= "string" then
			answer("unknown")
			return
		end
		answer(has_active_vpn_interface(stdout) and "up" or "down")
	end)
	return handle.start() == true
end

return M
