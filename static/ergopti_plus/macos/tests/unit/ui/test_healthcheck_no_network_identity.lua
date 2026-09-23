--- tests/unit/ui/test_healthcheck_no_network_identity.lua

--- ==============================================================================
--- MODULE: Healthcheck Collects No Network Identity (macOS)
--- DESCRIPTION:
--- The System diagnostics reported an unsalted SHA-256 of the Wi-Fi name. A
--- hash of a network name is reversed with a dictionary of common names, and
--- the diagnostics now leave the machine through Debug > Report a bug, so the
--- Wi-Fi name is not collected at all (no-network-identity).
--- ==============================================================================

local helpers = require("tests.helpers")

-- What the adapter answers on a Wi-Fi network: the digest of its name
local SSID_DIGEST = "5f0a3c9e81b2d4f6a7c8e9d0b1a2c3d4e5f60718293a4b5c6d7e8f9012345678"

helpers.describe("healthcheck: no network identity (no-network-identity)", function()
	helpers.it("the system facts carry no Wi-Fi name, hashed or not (no-network-identity)", function()
		local saved = package.loaded["adapters.network_info"]
		local ok, err = xpcall(function()
			helpers.load_with_stubs("infra.logger", { execute = function() return "" end })
			package.loaded["adapters.network_info"] = {
				getSsidHash = function() return SSID_DIGEST end,
				getSignalStrength = function() return 70 end,
				isInternetReachable = function() return true end,
				isVpnActive = function() return false end,
			}
			package.loaded["ui.healthcheck.helpers"] = nil
			local info = require("ui.healthcheck.helpers").sys_info()
			helpers.assert_true(type(info) == "table" and next(info) ~= nil, "sys_info must report its facts")
			helpers.assert_nil(info.wifi_ssid_hash, "the Wi-Fi name digest must not be collected")
			for key, value in pairs(info) do
				helpers.assert_true(tostring(value) ~= SSID_DIGEST, key .. " carries the Wi-Fi name digest")
			end
		end, debug.traceback)
		package.loaded["adapters.network_info"] = saved
		package.loaded["ui.healthcheck.helpers"] = nil
		if not ok then error(err, 0) end
	end)
end)
