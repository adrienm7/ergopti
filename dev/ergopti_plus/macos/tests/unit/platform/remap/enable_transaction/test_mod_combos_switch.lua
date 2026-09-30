--- tests/unit/platform/remap/enable_transaction/test_mod_combos_switch.lua

--- ==============================================================================
--- MODULE: The Key-Combinations Switch Of The Remap Facade
--- DESCRIPTION:
--- The « Combinaisons de touches » first-row checkbox reads and writes the
--- remap facade. It never follows Tap-Holds (decision of 2026-09-29): while
--- the user never set it, it is on; once set, the choice is persisted in the
--- same exact transaction as every other remap setting.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.remap_transaction_fixture")

helpers.describe("the remap facade owns the key-combinations switch", function()
	helpers.it("is on until set, whatever Tap-Holds say, then persists its own choice (combos-own-switch)", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap()
			helpers.assert_true(remap.set_tap_holds_enabled(true))
			helpers.assert_true(remap.get_mod_combos_enabled(), "an unset switch is on with Tap-Holds on")
			helpers.assert_true(remap.set_tap_holds_enabled(false))
			helpers.assert_true(remap.get_mod_combos_enabled(), "an unset switch stays on with Tap-Holds off")
			helpers.assert_nil(calls.saved_payloads[#calls.saved_payloads].mod_combos_enabled,
				"switching Tap-Holds writes no flag of its own")

			helpers.assert_true(remap.set_mod_combos_enabled(true))
			helpers.assert_true(remap.get_mod_combos_enabled(), "the explicit choice is on with Tap-Holds off")
			helpers.assert_eq(calls.saved_payloads[#calls.saved_payloads].mod_combos_enabled, true,
				"the choice is persisted")
			helpers.assert_true(remap.set_tap_holds_enabled(true))
			helpers.assert_true(remap.set_mod_combos_enabled(false))
			helpers.assert_eq(remap.get_mod_combos_enabled(), false, "off stays off with Tap-Holds on")
		end)
	end)

	-- The key combinations are drawn under Shortcuts: the Tap-Hold submenu's
	-- restore and clear rows must not switch them back on or wipe their pairs.
	helpers.it("survives the Tap-Hold submenu's restore and clear", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap()
			remap.regenerate = function(on_done)
				if on_done then on_done(true, "ready") end
				return true
			end
			helpers.assert_true(remap.set_tap_action("left_shift", "escape"))
			helpers.assert_true(remap.set_combo_combo_action("left_shift+right_shift", "escape"))
			helpers.assert_true(remap.set_combo_symmetric(true))
			helpers.assert_true(remap.set_mod_combos_enabled(false))

			local restored
			helpers.assert_true(remap.reset_tap_holds_to_defaults(function(ok) restored = ok end))
			helpers.assert_true(restored == true)
			helpers.assert_eq(remap.get_tap_action("left_shift"), "none", "the tap-holds are restored")
			helpers.assert_eq(remap.get_mod_combos_enabled(), false, "the switch stays off")
			helpers.assert_eq(calls.saved_payloads[#calls.saved_payloads].mod_combos_enabled, false,
				"the switch stays persisted")
			helpers.assert_eq(remap.get_combo_combo_action("left_shift+right_shift"), "escape",
				"a pair keeps its action through the restore")
			helpers.assert_true(remap.get_combo_symmetric(), "the symmetric choice is kept")

			local cleared
			helpers.assert_true(remap.set_tap_action("left_shift", "escape"))
			helpers.assert_true(remap.clear_tap_hold_bindings(function(ok) cleared = ok end))
			helpers.assert_true(cleared == true)
			helpers.assert_eq(remap.get_tap_action("left_shift"), "none", "the tap-holds are cleared")
			helpers.assert_eq(remap.get_combo_combo_action("left_shift+right_shift"), "escape",
				"a pair keeps its action through the clear")

			helpers.assert_true(remap.reset_to_defaults(function() end))
			helpers.assert_eq(remap.get_combo_combo_action("left_shift+right_shift"), "none",
				"the global restore still resets the pairs")
			helpers.assert_true(remap.get_mod_combos_enabled(), "and the switch is absent, so on, again")
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
