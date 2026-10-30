--- tests/unit/ui/menu/test_word_expander_consumption_rows.lua

--- ==============================================================================
--- MODULE: Word Expander Consumption Rows (PAR-8)
--- DESCRIPTION:
--- A catalogue row switches its delimiter on or off, so the consumed choice has its
--- own rows, and the restore command returns that choice to the catalogue too. The
--- owner calls are asserted on the real delimiter table; the row's wiring, inside
--- the menu builder's provider closure, is read from its source.
--- ==============================================================================

local helpers = require("tests.helpers")
local Terminators = require("keymap.terminators")

helpers.describe("word expander consumption rows", function()
	helpers.it("the choice flips without touching the on/off switch", function()
		local enabled = Terminators.is_terminator_enabled("comma")
		local consumed = Terminators.is_terminator_consume("comma")
		helpers.assert_eq(Terminators.set_terminators_consume({ comma = not consumed }), true)
		local flipped = Terminators.is_terminator_consume("comma")
		local switch = Terminators.is_terminator_enabled("comma")
		helpers.assert_eq(Terminators.set_terminators_consume({ comma = consumed }), true)
		helpers.assert_eq(flipped, not consumed)
		helpers.assert_eq(switch, enabled)
	end)

	helpers.it("the builder draws the rows and restores the choice", function()
		local handle = assert(io.open("ui/menu/menu_builder.lua", "rb"))
		local source = handle:read("*a")
		handle:close()
		for _, needle in ipairs({
			'["parameter_consume_children"] = consume_rows',
			"Terminators.set_terminators_consume({ [key] = next_consume })",
			"Terminators.set_terminators_consume(consumption)",
		}) do
			helpers.assert_true(source:find(needle, 1, true) ~= nil, needle)
		end
	end)
end)
