--- tests/unit/platform/remap/enable_transaction/test_mod_combos_switch.lua

--- ==============================================================================
--- MODULE: The Key-Combinations Switch Of The Remap Facade
--- DESCRIPTION:
--- The « Combinaisons de touches » first-row checkbox reads and writes the
--- remap facade. While the user never set it, the switch follows Tap-Holds;
--- once set, the choice is persisted in the same exact transaction as every
--- other remap setting and no longer follows.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.remap_transaction_fixture")

helpers.describe("the remap facade owns the key-combinations switch", function()
	helpers.it("follows Tap-Holds until set, then persists its own choice", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap()
			helpers.assert_true(remap.set_tap_holds_enabled(true))
			helpers.assert_true(remap.get_mod_combos_enabled(), "an unset switch follows Tap-Holds on")
			helpers.assert_true(remap.set_tap_holds_enabled(false))
			helpers.assert_eq(remap.get_mod_combos_enabled(), false, "an unset switch follows Tap-Holds off")
			helpers.assert_nil(calls.saved_payloads[#calls.saved_payloads].mod_combos_enabled,
				"following Tap-Holds writes no flag of its own")

			helpers.assert_true(remap.set_mod_combos_enabled(true))
			helpers.assert_true(remap.get_mod_combos_enabled(), "the explicit choice wins over Tap-Holds off")
			helpers.assert_eq(calls.saved_payloads[#calls.saved_payloads].mod_combos_enabled, true,
				"the choice is persisted")
			helpers.assert_true(remap.set_tap_holds_enabled(true))
			helpers.assert_true(remap.set_mod_combos_enabled(false))
			helpers.assert_eq(remap.get_mod_combos_enabled(), false, "off stays off with Tap-Holds on")
		end)
	end)

	helpers.it("refuses a value that is not a boolean", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap()
			local saves = calls.save
			helpers.assert_eq(remap.set_mod_combos_enabled("yes"), false)
			helpers.assert_eq(calls.save, saves, "nothing is persisted")
		end)
	end)
end)
