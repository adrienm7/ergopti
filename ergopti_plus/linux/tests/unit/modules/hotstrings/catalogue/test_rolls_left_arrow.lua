--- tests/unit/modules/hotstrings/catalogue/test_rolls_left_arrow.lua

--- ==============================================================================
--- MODULE: Rolls Left Arrow Section (Linux)
--- DESCRIPTION:
--- hotstrings.rolls.left_arrow is a Linux feature with no dedicated test. Drive
--- the shipped Ergopti rolls file through the real discovery and loader and pin
--- the section the toggle addresses: its one rule, its output and flags, and
--- its opt-in default (the generic section filter is pinned by
--- test_section_opt_in_defaults.lua).
--- ==============================================================================

package.loaded["tests.support.modules.hotstrings.catalogue.ergopti_extension_hotstrings_fixture"] = nil
local Fixture = require("tests.support.modules.hotstrings.catalogue.ergopti_extension_hotstrings_fixture")
local helpers, load = Fixture.helpers, Fixture.load

helpers.describe("rolls left_arrow section through the Linux loader (linux-rolls-left-arrow)", function()
	helpers.it("loads exactly the shipped left_arrow rule under the toggle's section", function()
		local catalogue = load(true)
		local rolls = assert(catalogue.categories.rolls, "the shipped rolls category loads")
		helpers.assert_true(rolls.sections.left_arrow ~= nil, "the toggle's section exists")
		helpers.assert_eq(rolls.sections.left_arrow.count, 1)
		local found = {}
		for _, m in ipairs(catalogue.mappings) do
			if m.group == "rolls" and m.section == "left_arrow" then found[#found + 1] = m end
		end
		helpers.assert_eq(#found, 1)
		local rule = found[1]
		helpers.assert_eq(rule.trigger, " = +")
		helpers.assert_eq(rule.replacement, " ➜ ")
		helpers.assert_eq(rule.auto_expand, true)
		helpers.assert_eq(rule.is_word, false)
	end)

	helpers.it("ships the section opt-in, like every bundled section", function()
		local default = require("infra.manifest_reader").default_for("hotstrings.rolls.left_arrow")
		helpers.assert_eq(default, { enabled = false })
	end)
end)
