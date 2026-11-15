--- _shared/tests/lua/pred_indent_default_contract.lua

--- ==============================================================================
--- MODULE: Prediction Indentation Default Contract
--- DESCRIPTION:
--- The assertions on the shipped indentation default the macOS and Linux tests
--- share; Windows asserts the same in test_llm_defaults.ahk.
--- ==============================================================================

--- pred-indent-default: the selected suggestion's indentation defaults to -3 on
--- every driver, where every line starts at one column and only the mark moves.
return function(helpers, default_value)
	helpers.describe("Prediction indentation default (pred-indent-default)", function()
		helpers.it("defaults to -3, where every line starts at one column", function()
			helpers.assert_eq(default_value, -3, "the driver's default")
			local selected, unselected = require("core.ui.engine.tooltip.llm_line").prefixes(default_value, 3, "▶", "·")
			helpers.assert_eq(selected, "▶", "the mark stands alone")
			helpers.assert_eq(unselected, selected, "the other lines carry the mark's width")
		end)
	end)
end
