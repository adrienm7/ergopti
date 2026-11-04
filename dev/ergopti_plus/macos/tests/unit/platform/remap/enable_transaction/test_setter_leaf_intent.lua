--- tests/unit/platform/remap/enable_transaction/test_setter_leaf_intent.lua

--- ==============================================================================
--- MODULE: Remap Setters Name The Leaf They Change
--- DESCRIPTION:
--- The remap writer replaces an obsolete leaf only when its save names that
--- leaf as the user's explicit choice (Config.explicit_leaves). Each menu setter
--- is that choice for exactly one leaf; the setters once sent no intent, so a
--- setting whose stored value was obsolete could never be changed again.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.remap_transaction_fixture")

local function last_intent(calls)
	local intent = calls.saved_intents[#calls.saved_intents]
	helpers.assert_type(intent, "table", "the setter's save names the leaf it changes")
	local names = {}
	for name in pairs(intent.leaves) do names[#names + 1] = name end
	table.sort(names)
	return table.concat(names, ",")
end

helpers.describe("remap setters send their own leaf intent (remap-leaf-intent)", function()
	helpers.it("each setter names exactly its own leaf (remap-leaf-intent)", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap()
			local cases = {
				{ function() return remap.set_mod_combos_enabled(false) end, "mod_combos.enabled" },
				{ function() return remap.set_tap_holds_enabled(true) end, "tap_holds.enabled" },
				{ function() return remap.set_combo_symmetric(true) end, "mod_combos.symmetric" },
				{ function() return remap.set_tap_hold_timeout(321) end, "tap_holds.timeout_ms" },
				{ function() return remap.set_sticky_timeout(654) end, "tap_holds.sticky_timeout_ms" },
				{ function() return remap.set_simultaneous_threshold(87) end, "mod_combos.simultaneous_threshold_ms" },
				{ function() return remap.set_tap_action("left_shift", "escape") end, "tap_holds.config.left_shift" },
				{ function() return remap.set_tap_timeout("left_shift", 150) end, "tap_holds.config.left_shift" },
				{ function() return remap.set_combo_tap_action("left_shift+right_shift", "escape") end,
					"mod_combos.config.left_shift+right_shift" },
			}
			for _, case in ipairs(cases) do
				helpers.assert_true(case[1](), case[2])
				helpers.assert_eq(last_intent(calls), case[2])
			end
		end)
	end)
end)

return true
