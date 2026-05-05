--- tests/unit/modules/keymap/test_terminators.lua

--- ==============================================================================
--- MODULE: keymap.terminators Unit Tests
--- DESCRIPTION:
--- Verifies the terminator catalogue, hot-path lookups, enable/disable
--- semantics, custom terminator lifecycle, and magic-key sync.
--- ==============================================================================

local helpers = require("tests.helpers")
local term    = helpers.load_with_stubs("modules.keymap.terminators")

helpers.describe("keymap.terminators: defaults", function()
	helpers.it("space is enabled by default", function()
		helpers.assert_true(term.is_terminator(" "))
	end)

	helpers.it("period is disabled by default", function()
		helpers.assert_true(not term.is_terminator("."))
	end)

	helpers.it("magic key (star) is enabled by default and consumed", function()
		helpers.assert_true(term.is_terminator("★"))
		helpers.assert_true(term.terminator_is_consumed("★"))
	end)

	helpers.it("get_terminator_defs returns the catalogue", function()
		local defs = term.get_terminator_defs()
		helpers.assert_true(#defs > 5)
	end)
end)

helpers.describe("keymap.terminators: enable/disable", function()
	helpers.it("toggles space off", function()
		term.set_terminator_enabled("space", false)
		helpers.assert_true(not term.is_terminator(" "))
		term.set_terminator_enabled("space", true)
		helpers.assert_true(term.is_terminator(" "))
	end)

	helpers.it("is_terminator_enabled mirrors state", function()
		term.set_terminator_enabled("comma", false)
		helpers.assert_true(not term.is_terminator_enabled("comma"))
		term.set_terminator_enabled("comma", true)
		helpers.assert_true(term.is_terminator_enabled("comma"))
	end)
end)

helpers.describe("keymap.terminators: hot-path", function()
	helpers.it("non-terminator character returns false", function()
		helpers.assert_true(not term.is_terminator("x"))
	end)

	helpers.it("first-codepoint fallback fires", function()
		-- Multi-codepoint event that starts with a terminator
		helpers.assert_true(term.is_terminator(" \u{0301}"))
	end)

	helpers.it("empty string is not a terminator", function()
		helpers.assert_true(not term.is_terminator(""))
	end)
end)

helpers.describe("keymap.terminators: custom lifecycle", function()
	helpers.it("adds a new custom terminator", function()
		term.add_custom_terminator("custom_x", "x", "x label", true)
		helpers.assert_true(term.is_terminator("x"))
		helpers.assert_true(term.terminator_is_consumed("x"))
	end)

	helpers.it("updates an existing custom terminator in place", function()
		term.add_custom_terminator("custom_x", "y", "y label", false)
		helpers.assert_true(term.is_terminator("y"))
		helpers.assert_true(not term.terminator_is_consumed("y"))
	end)

	helpers.it("removes a custom terminator", function()
		term.remove_custom_terminator("custom_x")
		helpers.assert_true(not term.is_terminator("y"))
	end)

	helpers.it("rejects invalid key/char gracefully", function()
		-- No throw expected
		term.add_custom_terminator(nil, "z", "label", false)
		helpers.assert_true(not term.is_terminator("z"))
	end)
end)

helpers.describe("keymap.terminators: magic key sync", function()
	helpers.it("retargets star to a new character", function()
		term.update_magic_key("§")
		helpers.assert_true(term.is_terminator("§"))
		helpers.assert_true(term.terminator_is_consumed("§"))
		-- restore
		term.update_magic_key("★")
	end)
end)
