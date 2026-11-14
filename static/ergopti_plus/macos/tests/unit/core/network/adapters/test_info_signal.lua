--- tests/unit/core/network/adapters/test_info_signal.lua

local helpers = require("tests.helpers")

helpers.describe("network signal availability", function()
	helpers.it("does not report signal quality for a disconnected interface", function()
		local details_read = false
		local adapter = helpers.load_with_stubs("core.network.adapters.info", { wifi = {
			currentNetwork = function() return nil end,
			interfaceDetails = function() details_read = true; return { rssi = 0 } end,
		} })
		helpers.assert_nil(adapter.getSignalStrength())
		helpers.assert_eq(details_read, false)
	end)

	helpers.it("rejects nonfinite measurements while preserving connected signal quality", function()
		local rssi = -50
		local adapter = helpers.load_with_stubs("core.network.adapters.info", { wifi = {
			currentNetwork = function() return "test-network" end,
			interfaceDetails = function() return { rssi = rssi } end,
		} })
		helpers.assert_eq(adapter.getSignalStrength(), 50)
		for _, invalid in ipairs({ 0/0, math.huge, -math.huge }) do
			rssi = invalid
			helpers.assert_nil(adapter.getSignalStrength())
		end
	end)
end)
