--- tests/unit/adapters/runtime/test_power_source.lua
local helpers = require("tests.helpers")

helpers.describe("power source fallback (power-source-fallback)", function()
	helpers.it("paces for the battery unless native power is known to be mains", function()
		local previous_hs = hs
		local result = nil
		hs = { battery = { powerSource = function()
			if result == "throw" then error("unavailable") end
			return result
		end } }
		local ok, err = pcall(function()
			local adapter = require("adapters.power_source")
			for _, case in ipairs({
				{ "Battery Power", true }, { "AC Power", false },
				{ "UPS Power", true }, { "unknown", true }, { "throw", true },
			}) do
				result = case[1]
				helpers.assert_eq(adapter.on_battery(), case[2], tostring(result))
			end
			result = nil
			helpers.assert_eq(adapter.on_battery(), true, "missing power source")
		end)
		hs = previous_hs
		if not ok then error(err, 0) end
	end)
end)
