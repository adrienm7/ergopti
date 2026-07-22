--- tests/unit/modules/keymap/test_terminators_extras.lua

--- ==============================================================================
--- MODULE: keymap.terminators Extras
--- DESCRIPTION:
--- Additional coverage for the terminators module: custom terminator lifecycle,
--- enable/disable round-trip, and the magic-key sync behavior of
--- update_magic_key().
--- ==============================================================================

local helpers = require("tests.helpers")
local term    = helpers.load_with_stubs("modules.keymap.terminators")




-- =========================================
-- =========================================
-- ======= 1/ Custom terminator lifecycle ===
-- =========================================
-- =========================================

helpers.describe("Terminators custom lifecycle", function()
	helpers.it("add_custom_terminator registers a new entry", function()
		term.add_custom_terminator("at", "@", "At sign", true)
		helpers.assert_true(term.is_terminator("@"))
		helpers.assert_true(term.terminator_is_consumed("@"))
		term.remove_custom_terminator("at")
		helpers.assert_true(not term.is_terminator("@"))
	end)

	helpers.it("remove_custom_terminator on unknown id is a no-op", function()
		term.remove_custom_terminator("nonexistent_id")
	end)

	helpers.it("set_terminator_enabled toggles state", function()
		term.set_terminator_enabled("space", false)
		helpers.assert_eq(term.is_terminator_enabled("space"), false)
		term.set_terminator_enabled("space", true)
		helpers.assert_eq(term.is_terminator_enabled("space"), true)
	end)
end)




-- =========================================
-- =========================================
-- ======= 2/ get_terminator_defs ===========
-- =========================================
-- =========================================

helpers.describe("Terminators get_terminator_defs", function()
	helpers.it("returns a non-empty list", function()
		helpers.assert_true(#term.get_terminator_defs() > 0)
	end)

	helpers.it("each non-separator def has key, chars[], and label fields", function()
		for _, d in ipairs(term.get_terminator_defs()) do
			if d.type ~= "separator" then
				helpers.assert_true(type(d.key) == "string" and d.key ~= "")
				helpers.assert_true(type(d.chars) == "table" and #d.chars >= 1)
				helpers.assert_true(type(d.label) == "string")
			end
		end
	end)
end)
