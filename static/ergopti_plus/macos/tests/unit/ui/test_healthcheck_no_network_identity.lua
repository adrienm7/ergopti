--- tests/unit/ui/test_healthcheck_no_network_identity.lua

--- ==============================================================================
--- MODULE: Healthcheck Collects No Network Identity (macOS)
--- DESCRIPTION:
--- The System diagnostics reported an unsalted SHA-256 of the Wi-Fi name. A
--- hash of a network name is reversed with a dictionary of common names, and
--- the diagnostics leave the machine through Debug > Report a bug, so nothing
--- that names a place or a device is collected: no Wi-Fi name, hashed or not,
--- no host name, no serial (no-network-identity).
--- ==============================================================================

local helpers = require("tests.helpers")

-- What the adapter answers on a Wi-Fi network: the digest of its name
local SSID_DIGEST = "5f0a3c9e81b2d4f6a7c8e9d0b1a2c3d4e5f60718293a4b5c6d7e8f9012345678"
local HOST_NAME = "Janes-MacBook-Pro"

--- Every string of a nested table.
--- @param value any
--- @param out table
--- @return table
local function strings_of(value, out)
	out = out or {}
	if type(value) == "string" then out[#out + 1] = value
	elseif type(value) == "table" then
		for key, item in pairs(value) do
			strings_of(key, out)
			strings_of(item, out)
		end
	end
	return out
end

helpers.describe("healthcheck: no network identity (no-network-identity)", function()
	helpers.it("the whole snapshot carries no Wi-Fi name and no host name (no-network-identity)", function()
		helpers.with_stub_scope({
			"infra.logger", "adapters.network_info", "ui.healthcheck.core", "ui.healthcheck.helpers",
		}, function()
			local asked = {}
			helpers.load_with_stubs("infra.logger", {
				execute = function(command) asked[#asked + 1] = command; return HOST_NAME end,
			})
			hs.host.localizedName = function() asked[#asked + 1] = "localizedName"; return HOST_NAME end
			hs.host.names = function() asked[#asked + 1] = "names"; return { HOST_NAME } end
			package.loaded["adapters.network_info"] = {
				getSsidHash = function() asked[#asked + 1] = "ssid"; return SSID_DIGEST end,
				getSignalStrength = function() return 70 end,
				isInternetReachable = function() return true end,
				isVpnActive = function() return false end,
			}
			package.loaded["ui.healthcheck.helpers"] = nil
			package.loaded["ui.healthcheck.core"] = nil
			local snapshot = require("ui.healthcheck.core").run({ detailed = true })
			helpers.assert_eq(snapshot.sections.network.wifi_signal, "70%", "the signal strength alone is reported")
			for _, text in ipairs(strings_of(snapshot)) do
				helpers.assert_true(not text:find(SSID_DIGEST, 1, true), "the Wi-Fi name digest was collected")
				helpers.assert_true(not text:find(HOST_NAME, 1, true), "the host name was collected")
			end
			helpers.assert_eq(asked, {}, "no collector may even ask for a network or host identity")
		end)
	end)
end)
