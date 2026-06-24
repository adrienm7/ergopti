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

-- Regression: the defaults are loaded in full from the shared
-- _shared/tap_hold/defaults.toml ([hs_*] sections), not a hardcoded Lua table.
-- A partial parse (e.g. a malformed inline-table line or a dropped section)
-- would silently shrink these sets — the shape tests above pass vacuously on an
-- empty table, so pin the exact counts and a few sentinel values here.
helpers.describe("karabiner.defaults: full set loaded from shared TOML", function()
	local function count(t)
		local n = 0
		for _ in pairs(t) do n = n + 1 end
		return n
	end

	helpers.it("loads all 14 tap/hold keys", function()
		helpers.assert_eq(count(D.tap_hold), 14)
	end)

	helpers.it("loads the full 14x13 = 182 combo matrix", function()
		helpers.assert_eq(count(D.combos), 182)
	end)

	helpers.it("preserves sentinel tap/hold defaults", function()
		helpers.assert_eq(D.tap_hold.caps_lock[1], "return")
		helpers.assert_eq(D.tap_hold.caps_lock[2], "cmd")
		helpers.assert_eq(D.tap_hold.tab[1], "alt_tab_windows")
		helpers.assert_eq(D.tap_hold.tab[2], "fn")
		helpers.assert_eq(D.tap_hold.left_command[2], "layer")
	end)

	helpers.it("preserves the rcmd_lcmd asymmetric hold (option_shift)", function()
		helpers.assert_eq(D.combos.rcmd_lcmd[3], "option_shift")
	end)
end)
