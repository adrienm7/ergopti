--- tests/unit/shortcuts/text_actions/test_wrap_guillemet_trigger.lua

--- ==============================================================================
--- MODULE: Typed guillemets reach the spaced catalogue pair (WSL-001)
--- DESCRIPTION:
--- The shared catalogue spells the French pair "« " / " »" so the output keeps
--- its spaces. The key a user types is the bare glyph (or the glyph with a
--- non-breaking space), so the real manager must publish those trigger forms
--- while the pair it returns still carries the spaced delimiters.
--- ==============================================================================

local helpers = require("tests.helpers")

local Shortcuts = helpers.load_module("shortcuts.engine.manager")

helpers.describe("shortcuts manager: guillemet triggers (WSL-001)", function()
	helpers.it("resolves the bare opening and closing guillemet to the spaced pair", function()
		for _, typed in ipairs({ "\194\171", "\194\187" }) do
			local pair = Shortcuts.get_wrap_pair(typed)
			helpers.assert_not_nil(pair, "typed guillemet must be a wrap trigger")
			helpers.assert_eq(pair.left, "\194\171 ", "output keeps the catalogue spacing")
			helpers.assert_eq(pair.right, " \194\187")
		end
	end)

	helpers.it("keeps ordinary pairs working", function()
		helpers.assert_eq(Shortcuts.get_wrap_pair("(").right, ")")
		helpers.assert_nil(Shortcuts.get_wrap_pair("a"))
	end)
end)
