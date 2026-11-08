--- tests/unit/platform/remap/enable_transaction/test_sticky_timeout_domain.lua

--- ==============================================================================
--- MODULE: One-Shot Shift Timeout Domain
--- DESCRIPTION:
--- The setter must admit exactly what arming and the editor can represent: a
--- positive whole number of milliseconds within the timer ceiling. A fraction
--- that floors to zero, NaN, an infinity and a value beyond the timer ceiling
--- (the menu's "1e309" and "1e20") were persisted once, then broke arming or
--- the next edit's integer dialog. A refusal changes neither state nor file.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.remap_transaction_fixture")

helpers.describe("one-shot Shift timeout domain (OSM-002)", function()
	helpers.it("refuses every value arming or the editor cannot represent, without a write", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap()
			local before = remap.get_sticky_timeout()
			local saves = #calls.saved_intents
			local refused = { 0.1, 0.9, 0, -5, 1.5, 0 / 0, math.huge, -math.huge, 1e20, "1e309", "1e20", "abc" }
			for _, candidate in ipairs(refused) do
				helpers.assert_eq(remap.set_sticky_timeout(candidate), false, "refuses " .. tostring(candidate))
			end
			helpers.assert_eq(remap.get_sticky_timeout(), before, "the live timeout is unchanged")
			helpers.assert_eq(#calls.saved_intents, saves, "nothing was saved")
		end)
	end)

	helpers.it("still admits whole positive milliseconds", function()
		with_fixture(function(fixture)
			local remap = fixture.load_enabled_remap()
			helpers.assert_true(remap.set_sticky_timeout(1))
			helpers.assert_eq(remap.get_sticky_timeout(), 1)
			helpers.assert_true(remap.set_sticky_timeout(2000))
			helpers.assert_eq(remap.get_sticky_timeout(), 2000)
		end)
	end)
end)

return true
