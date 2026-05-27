--- tests/unit/modules/karabiner/test_defaults.lua

--- ==============================================================================
--- MODULE: karabiner.defaults Unit Tests
--- DESCRIPTION:
--- Sanity checks for the karabiner defaults table — keys present, values
--- well-formed, and the few documented invariants (e.g. simultaneous_threshold
--- in a sane range).
--- ==============================================================================

local helpers = require("tests.helpers")
local D = helpers.load_with_stubs("modules.karabiner.defaults")

helpers.describe("karabiner.defaults: timing constants", function()
	helpers.it("tap_hold_timeout_ms is positive", function()
		helpers.assert_true(D.tap_hold_timeout_ms > 0)
	end)

	helpers.it("sticky_timeout_ms is positive", function()
		helpers.assert_true(D.sticky_timeout_ms > 0)
	end)

	helpers.it("simultaneous_threshold_ms is in a sane range", function()
		helpers.assert_true(D.simultaneous_threshold_ms >= 50 and D.simultaneous_threshold_ms <= 500,
			"chord activation window should be 50–500 ms")
	end)

	helpers.it("combo_symmetric is a boolean", function()
		helpers.assert_true(type(D.combo_symmetric) == "boolean")
	end)
end)

helpers.describe("karabiner.defaults: tap_hold table", function()
	helpers.it("each entry is a 2-tuple of strings", function()
		for key, pair in pairs(D.tap_hold) do
			helpers.assert_true(type(pair) == "table", key .. " should be a table")
			helpers.assert_true(#pair == 2, key .. " should have exactly 2 elements")
			helpers.assert_true(type(pair[1]) == "string", key .. ".tap should be a string")
			helpers.assert_true(type(pair[2]) == "string", key .. ".hold should be a string")
		end
	end)
end)

helpers.describe("karabiner.defaults: combos table", function()
	helpers.it("each entry is a 3-tuple of strings", function()
		for key, triple in pairs(D.combos) do
			helpers.assert_true(type(triple) == "table", key)
			helpers.assert_true(#triple == 3, key .. " should have 3 elements")
			for i, v in ipairs(triple) do
				helpers.assert_true(type(v) == "string", key .. "[" .. i .. "] should be string")
			end
		end
	end)

	helpers.it("contains the documented rcmd combos", function()
		helpers.assert_true(D.combos.rcmd_caps ~= nil)
		helpers.assert_eq(D.combos.rcmd_caps[1], "capsword")
		helpers.assert_eq(D.combos.rcmd_lcmd[1], "opt_backspace")
	end)
end)
