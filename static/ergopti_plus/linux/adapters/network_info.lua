--- linux/adapters/network_info.lua

--- ==============================================================================
--- MODULE: NetworkInfo Adapter (Linux)
--- DESCRIPTION:
--- Linux implementation of the NetworkInfo port contract defined in
--- static/ergopti_plus/shared/ports/NetworkInfo.spec.js. Wraps iwgetid/nmcli,
--- ping, and ip/ifconfig to expose Wi-Fi SSID hash, signal strength, internet
--- reachability, and VPN detection without coupling domain modules to
--- platform-specific APIs.
---
--- FEATURES & RATIONALE:
--- 1. Hashed SSID: the raw SSID is never stored or returned; getSsidHash()
---    returns the SHA-256 digest so callers compare known networks without
---    exposing the plaintext SSID.
--- 2. Null-on-disconnect: Wi-Fi methods return nil when no interface is
---    connected, matching the port contract error_behavior.
--- 3. iwgetid with nmcli fallback: iwgetid is the lightest CLI for SSID; nmcli
---    covers NetworkManager-managed interfaces where iwgetid may fail.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")

local LOG = "adapters.network_info"


-- =========================================
-- =========================================
-- ======= 1/ Internal Helpers =============
-- =========================================
-- =========================================

--- Computes the SHA-256 hex digest of a string via openssl.
--- @param s string
--- @return string hex digest or ""
local function _sha256_hex(s)
	if type(s) ~= "string" or s == "" then return "" end
	local ok, out = pcall(function()
		local cmd = string.format(
			"printf '%%s' %q | openssl dgst -sha256 -hex 2>/dev/null", s)
		local fh = io.popen(cmd, "r")
		if not fh then return "" end
		local result = fh:read("*a")
		fh:close()
		return result
	end)
	if not ok or type(out) ~= "string" then return "" end
	local hex = out:match("[0-9a-f]+%s*$") or ""
	return hex:gsub("%s+", "")
end

--- Returns the raw SSID of the active Wi-Fi interface, or nil.
--- Tries iwgetid first, then nmcli as fallback.
local function _get_raw_ssid()
	-- iwgetid: lightweight, works without NetworkManager
	local fh = io.popen("iwgetid -r 2>/dev/null", "r")
	if fh then
		local ssid = fh:read("*a")
		fh:close()
		if type(ssid) == "string" then
			ssid = ssid:match("^%s*(.-)%s*$")
			if ssid ~= "" then return ssid end
		end
	end
	-- nmcli fallback: covers NetworkManager environments
	fh = io.popen("nmcli -t -f active,ssid dev wifi 2>/dev/null | grep '^yes'", "r")
	if fh then
		local line = fh:read("*a")
		fh:close()
		if type(line) == "string" then
			local ssid = line:match("^yes:(.+)$")
			if ssid then
				return ssid:match("^%s*(.-)%s*$")
			end
		end
	end
	return nil
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
		local ssid = _get_raw_ssid()
		if not ssid then return nil end
		return _sha256_hex(ssid)
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
		-- /proc/net/wireless: ESSID  Status  Link  Level  Noise
		local fh = io.open("/proc/net/wireless", "r")
		if not fh then return nil end
		local content = fh:read("*a")
		fh:close()
		-- Lines 3+: " wlan0: 0000  70.  -40.  -256. ..."
		local link = content:match("%w+:%s*%d+%s+(%d+)%.")
		if not link then return nil end
		local quality = tonumber(link) or 0
		-- link quality is 0-70 on most drivers; normalize to 0-100
		return math.min(100, math.floor(quality * 100 / 70))
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
		local code = os.execute(
			"ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1")
		return code == true or code == 0
	end)
	if not ok then
		Logger.error(LOG, "isInternetReachable(): error — %s", tostring(result))
		return false
	end
	return result == true
end

--- Returns whether at least one VPN tunnel interface (tun/tap/wg) is up.
--- @return boolean
function M.isVpnActive()
	local ok, result = pcall(function()
		local fh = io.popen(
			"ip link show 2>/dev/null | grep -cE 'tun[0-9]|tap[0-9]|wg[0-9]'", "r")
		if not fh then return false end
		local out = fh:read("*a")
		fh:close()
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
